## MODIFIED Requirements

### Requirement: Launched Claude sessions run in a named tmux session on the Pi

Every Claude Code session that SpecForge starts for Lead Agent or specialist
work SHALL run inside a tmux session on the Pi host, managed under a dedicated
tmux server socket reserved for SpecForge. Each such session SHALL have a
deterministic name that encodes its role and its mapped Bead. SpecForge SHALL
NOT create a session whose name collides with an existing managed session; on a
name collision it SHALL either fail or generate a new distinct name, and SHALL
never reuse or overwrite the existing session.

The **Orchestration Agent** session is the one exception: it is not anchored to
a Bead, its name is the fixed singleton `sf-orchestrator-<slug>`, and
`scripts/specforge orchestrator run` SHALL **adopt** an existing live session
of that name (re-attach its log pipe and refresh its record) rather than fail
or rename — this is what makes the supervisor idempotent and the role
single-instance.

#### Scenario: A launched session is a named tmux session

- **WHEN** SpecForge launches a Claude session for a role and a Bead
- **THEN** a tmux session exists on the Pi under the SpecForge tmux server socket
- **AND** its name encodes the role and the Bead ID
- **AND** the Claude process runs inside that tmux session

#### Scenario: Session names do not collide

- **WHEN** SpecForge launches a session and the generated name already belongs to a managed session
- **THEN** SpecForge does not attach to, reuse, or overwrite the existing session
- **AND** it either fails with a clear message or creates a session under a different distinct name

#### Scenario: Managed sessions are isolated from the operator's own tmux

- **WHEN** an operator runs `tmux list-sessions` against their default tmux server
- **THEN** SpecForge-managed sessions are not listed there
- **AND** they are listed only under the dedicated SpecForge tmux server socket

#### Scenario: The orchestrator session is adopted, not duplicated

- **WHEN** `orchestrator run` is invoked and a live `sf-orchestrator-<slug>` session already exists
- **THEN** it adopts that session and refreshes its record
- **AND** it does not create a second orchestrator session

### Requirement: Each session has durable runtime metadata

For every launched session SpecForge SHALL persist a metadata record to disk
containing at least the role, the start time, the working directory, the
launch command, the owner, and a lifecycle state, plus the Bead ID for a Lead
or specialist session. The Orchestration Agent record SHALL carry a null Bead
ID and SHALL additionally record whether the command floor was lifted for that
session. The record SHALL be written before the Claude process starts and SHALL
be updated on every lifecycle-state transition. The record SHALL remain
readable after the process that launched the session has exited or restarted.

#### Scenario: Metadata is recorded at launch

- **WHEN** SpecForge launches a session
- **THEN** a persisted metadata record exists for it before the Claude process begins work
- **AND** it contains the role, the start time, the working directory, the launch command, the owner, and the current state

#### Scenario: An orchestrator record carries no Bead and marks full access

- **WHEN** SpecForge starts the Orchestration Agent session
- **THEN** its metadata record has a null Bead ID
- **AND** it records that the command floor was lifted

#### Scenario: Metadata survives a restart of the launcher

- **WHEN** the process that launched a session exits and SpecForge is invoked again
- **THEN** the session's metadata record is still available
- **AND** it still identifies the role and the working directory

#### Scenario: State transitions are reflected in the record

- **WHEN** a session moves from running to stopped
- **THEN** its metadata record shows the terminal state
- **AND** it records when the session ended and why

## ADDED Requirements

### Requirement: An orchestrator subcommand group drives the always-on session

`scripts/specforge` SHALL provide an `orchestrator` subcommand group:

- `run` — the idempotent supervisor invoked by the systemd service: acquire
  the orchestrator lock, adopt or create the `sf-orchestrator-<slug>` session
  (resuming a prior conversation with `claude --continue` when one exists for
  the working directory), refresh the record, block until the tmux session
  exits, release the lock, and exit non-zero so the service restarts it.
- `status` — the service's enabled/active state, whether user lingering is on,
  whether a `FULL-ACCESS` orchestrator session is live, the record, and the
  last log lines; read-only.
- `stop` — stop and disable the service, mark the record terminal, release the
  lock; idempotent.
- `restart` — restart the service.

`run` SHALL NOT require a `--bead` argument.

#### Scenario: run resumes a prior conversation

- **WHEN** `orchestrator run` starts and a prior Claude conversation exists for the working directory and no live session
- **THEN** it launches `claude --continue` in the orchestrator tmux session

#### Scenario: stop is idempotent

- **WHEN** `orchestrator stop` is invoked twice
- **THEN** the second call succeeds without error and the service stays disabled
