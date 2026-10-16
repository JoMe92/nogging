## MODIFIED Requirements

### Requirement: Each session has an inspectable log

Each launched session SHALL stream its console output to an append-only log
file whose path is recorded in the session metadata. The log SHALL be readable
without attaching to the backend session.

Output SHALL reach the log as it arrives, without waiting for a line break, so
the log of a full-screen agent that emits few line feeds grows while the
session runs. The log writer SHALL hold at most a bounded chunk of output in
memory. Log growth SHALL be bounded by the configured size limit with
rotation, and no log generation SHALL exceed that limit. The writer SHALL
preserve the output bytes exactly.

A Claude Code session MAY additionally have a structured events file
(`<name>.events.jsonl`) written by its own hooks; where present, this file
supplements the console log and SHALL NOT replace it — the console log remains
the complete record regardless of whether the events file exists.

#### Scenario: Session output is captured to a log

- **WHEN** a session produces console output
- **THEN** that output is appended to the session's log file
- **AND** the log file path is present in the session's metadata record

#### Scenario: The log is readable without attaching

- **WHEN** an operator reads or follows a session's log from an SSH shell
- **THEN** they see the session's output
- **AND** they do not attach to or disturb the backend session

#### Scenario: A full-screen agent's log grows live

- **WHEN** a running session emits output that contains no line feed
- **THEN** that output appears in the log before the session ends

#### Scenario: Log size is bounded

- **WHEN** a session's output, with or without line feeds, exceeds the configured size limit
- **THEN** the log is rotated
- **AND** no log generation exceeds the configured size limit

#### Scenario: An events file supplements, never replaces, the console log

- **WHEN** a Claude Code session has written at least one line to its
  `<name>.events.jsonl`
- **THEN** the session's console log is still complete and still readable on
  its own

### Requirement: Attach, stop and cleanup are deliberate operations

Attaching to, stopping and cleaning up a session SHALL each be an explicit
operator command and SHALL NOT occur as a side effect of another operation.

Stopping a session SHALL terminate its agent process and its backend session,
and SHALL record a final state with the time and reason.

Cleanup SHALL remove the backend session and retire its metadata. It SHALL run
only for a session that has completed its task or been stopped, and SHALL
refuse to act on a session that is still starting, running or idle.

Cleanup SHALL archive the session's log together with every rotated
generation of it. Cleanup SHALL stop the dedicated Nogging tmux server only
when that server's own session listing succeeds and reports no session. That
the current checkout has no remaining record SHALL NOT be a reason to stop a
server that still hosts the Orchestration Agent or another checkout's session.
Cleanup SHALL never stop the herdr server.

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

#### Scenario: Cleanup in a quiet checkout keeps the shared tmux server

- **WHEN** cleanup retires the last record of a checkout while the Orchestration Agent runs on the shared tmux server
- **THEN** the tmux server and the Orchestration Agent session keep running

#### Scenario: Cleanup archives every log generation

- **WHEN** cleanup retires a session whose log has rotated generations
- **THEN** the active log and every rotated generation are archived
- **AND** no generation of that log is left in place

#### Scenario: Attach never happens automatically

- **WHEN** Nogging launches, lists, logs, stops or cleans up a session
- **THEN** no attach is performed as part of that operation
