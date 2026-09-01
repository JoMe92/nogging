## ADDED Requirements

### Requirement: Launched Claude sessions run in a named tmux session on the Pi

Every Claude Code session that SpecForge starts for Lead Agent or specialist
work SHALL run inside a tmux session on the Pi host, managed under a dedicated
tmux server socket reserved for SpecForge. Each session SHALL have a
deterministic name that encodes its role and its mapped Bead. SpecForge SHALL
NOT create a session whose name collides with an existing managed session; on a
name collision it SHALL either fail or generate a new distinct name, and SHALL
never reuse or overwrite the existing session.

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

### Requirement: Each session has durable runtime metadata

For every launched session SpecForge SHALL persist a metadata record to disk
containing at least the Bead ID, the role, the start time, the working
directory, the launch command, the owner, and a lifecycle state. The record
SHALL be written before the Claude process starts and SHALL be updated on every
lifecycle-state transition. The record SHALL remain readable after the process
that launched the session has exited or restarted.

#### Scenario: Metadata is recorded at launch

- **WHEN** SpecForge launches a session
- **THEN** a persisted metadata record exists for it before the Claude process begins work
- **AND** it contains the Bead ID, the role, the start time, the working directory, the launch command, the owner, and the current state

#### Scenario: Metadata survives a restart of the launcher

- **WHEN** the process that launched a session exits and SpecForge is invoked again
- **THEN** the session's metadata record is still available
- **AND** it still identifies the Bead, the role, and the working directory

#### Scenario: State transitions are reflected in the record

- **WHEN** a session moves from running to stopped
- **THEN** its metadata record shows the terminal state
- **AND** it records when the session ended and why

### Requirement: Sessions are listable and attachable remotely over SSH

SpecForge SHALL provide a command, runnable from an ordinary SSH shell, that
lists every managed session together with its runtime metadata without
attaching to any session. SpecForge SHALL provide a separate command to attach
to a named session, including a read-only attach option. Listing SHALL
reconcile each metadata record against live tmux state and report a record
whose tmux session is gone as failed rather than running.

#### Scenario: An operator lists sessions over SSH

- **WHEN** an operator connects to the Pi over SSH and runs the session list command
- **THEN** every managed session is shown with its Bead ID, role, start time, working directory, owner, and state
- **AND** the command does not attach to any session

#### Scenario: An operator attaches to a chosen session

- **WHEN** an operator runs the attach command with a managed session name
- **THEN** their terminal is attached to that tmux session
- **AND** a read-only option is available that prevents sending input to the session

#### Scenario: A dead session is reported as failed

- **WHEN** a metadata record is in the running state but its tmux session no longer exists
- **THEN** the list command reports that session as failed
- **AND** it does not report it as running

### Requirement: Each session has an inspectable log

Each launched session SHALL stream its console output to an append-only log
file whose path is recorded in the session metadata. The log SHALL be readable
without attaching to the tmux session. Log file growth SHALL be bounded by a
configured size limit with rotation.

#### Scenario: Session output is captured to a log

- **WHEN** a session produces console output
- **THEN** that output is appended to the session's log file
- **AND** the log file path is present in the session's metadata record

#### Scenario: The log is readable without attaching

- **WHEN** an operator reads or follows a session's log from an SSH shell
- **THEN** they see the session's output
- **AND** they do not attach to or disturb the tmux session

#### Scenario: Log size is bounded

- **WHEN** a session's log file reaches the configured size limit
- **THEN** it is rotated
- **AND** the active log file does not grow without bound

### Requirement: Attach, stop and cleanup are deliberate operations

Attaching to, stopping, and cleaning up a session SHALL each be an explicit
operator command and SHALL NOT occur as a side effect of another operation.
Stopping a session SHALL terminate its Claude process and its tmux session and
SHALL record a final state with the time and reason. Cleanup SHALL remove the
tmux session and retire its metadata, and SHALL run only for a session that has
completed its task or been stopped. Cleanup SHALL refuse to act on a session
that is still starting, running or idle.

#### Scenario: Stopping a session records a final state

- **WHEN** an operator stops a running session
- **THEN** the Claude process and the tmux session are terminated
- **AND** the metadata record shows a terminal state with the end time and the stop reason

#### Scenario: Cleanup refuses a running session

- **WHEN** an operator runs cleanup against a session whose state is starting, running or idle
- **THEN** cleanup does not remove the tmux session or the metadata
- **AND** it reports that the session must be stopped first

#### Scenario: Cleanup runs after completion or stop

- **WHEN** a session has completed its task or been stopped and an operator runs cleanup for it
- **THEN** the tmux session is removed
- **AND** the metadata record is retired

#### Scenario: Attach never happens automatically

- **WHEN** SpecForge launches, lists, logs, stops or cleans up a session
- **THEN** no tmux attach is performed as part of that operation

### Requirement: A launched session never claims a task autonomously

A session launched by SpecForge SHALL NOT claim a Bead or move a Bead into an
in-progress state as an automatic consequence of being launched. The launch
command itself SHALL perform no Beads mutation. Claiming or starting a Bead
SHALL remain a deliberate action taken on operator direction.

#### Scenario: Launch performs no Beads mutation

- **WHEN** SpecForge launches a session for a Bead
- **THEN** the launch command does not claim, start, or otherwise mutate that Bead or any other Bead

#### Scenario: A launched session does not self-assign work

- **WHEN** a session starts and no Bead has been claimed for it by an operator or the Main Worker
- **THEN** the session does not autonomously select a ready Bead and claim it

### Requirement: Session supervision uses least authority and never logs credentials

SpecForge SHALL launch each Claude session with a restricted permission profile
that grants no more authority than the delegated work requires, and in
particular without the ability to push to a remote or run remote Dolt sync
unless the work explicitly requires it. Secrets SHALL NOT be passed as
command-line arguments. The persisted launch command and the session log SHALL
NOT contain credential or token values. The tmux server and the Claude process
SHALL run as a non-privileged user.

#### Scenario: Restricted profile withholds push authority

- **WHEN** SpecForge launches a specialist session
- **THEN** that session cannot push to a git remote or run a remote Dolt sync through its permission profile

#### Scenario: The recorded command contains no secrets

- **WHEN** a session's metadata record is read
- **THEN** its stored launch command contains no credential or token values

#### Scenario: The log contains no credentials

- **WHEN** a session's log is inspected
- **THEN** it does not contain credential or token values echoed from the environment or the launch wrapper

#### Scenario: Supervision does not require elevated privileges

- **WHEN** SpecForge starts the tmux server and a Claude session
- **THEN** both run as the same non-privileged user
- **AND** no privilege escalation is used
