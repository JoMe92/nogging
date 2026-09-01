## ADDED Requirements

### Requirement: Closed mapped Beads are reconciled into OpenSpec

The mechanical sync SHALL enumerate every mapped Bead whose status is `closed`,
in addition to non-closed mapped Beads, and SHALL mirror each closed mapped Bead
to its mapped task checkbox and to the change's `execution-log.md`. The mirror
SHALL be idempotent: running sync again after a closed mapped Bead has been
mirrored SHALL NOT add a second execution-log entry for the same closure and
SHALL NOT modify an already-checked task.

#### Scenario: A closed mapped Bead is mirrored on the next sync

- **WHEN** a mapped Bead is closed and sync runs
- **THEN** the mapped task in `tasks.md` is checked
- **AND** an execution-log entry for that Bead closure is appended to the change's `execution-log.md`

#### Scenario: Re-running sync does not duplicate a mirrored closure

- **WHEN** a closed mapped Bead has already been mirrored by a previous sync
- **AND** sync runs again with no other change
- **THEN** no new execution-log entry is written
- **AND** the mapped task checkbox is left unchanged
- **AND** sync reports that it made no changes

#### Scenario: A Bead closed between sync runs is still mirrored

- **WHEN** a mapped Bead was open at the previous sync and is closed before the next sync
- **THEN** the next sync mirrors its closure to the task checkbox and the execution log

### Requirement: Execution-log entries record closure evidence

Each execution-log entry written for a Bead closure SHALL record the Bead ID,
the closure timestamp, the Bead's human-readable note, and any implementation
commit references that can be determined. When no implementation commit
reference can be determined, the entry SHALL still be written and SHALL state
that none was found.

#### Scenario: Entry includes commit references when present

- **WHEN** sync mirrors a closed Bead whose closure can be tied to one or more implementation commits
- **THEN** the execution-log entry lists those commit references
- **AND** the entry includes the Bead ID and the closure timestamp
- **AND** the entry includes the Bead's human-readable note

#### Scenario: Entry is written even without a commit reference

- **WHEN** sync mirrors a closed Bead and no implementation commit reference can be determined
- **THEN** the execution-log entry is still written
- **AND** the entry states that no implementation commit reference was found

#### Scenario: The Bead note is preserved verbatim

- **WHEN** sync mirrors a closed Bead that has a human-readable note
- **THEN** the note text appears in the execution-log entry without being reformatted or truncated

### Requirement: Discovery review surfaces closed discoveries

Discovery review SHALL enumerate every Bead carrying the `discovery` label
regardless of the Bead's status, so that a discovery closed before a planning
session reviews it is not omitted. A discovery that a planning session has
explicitly acknowledged SHALL stop being surfaced; a discovery that has not been
acknowledged SHALL keep being surfaced whether it is open or closed. Blocking
discoveries SHALL continue to be presented before non-blocking ones.

#### Scenario: An open discovery is listed

- **WHEN** an open Bead carries the `discovery` label and has not been acknowledged
- **THEN** discovery review lists it

#### Scenario: A closed, unacknowledged discovery is listed

- **WHEN** a Bead carries the `discovery` label, is closed, and has not been acknowledged
- **THEN** discovery review lists it and marks it as closed and awaiting review

#### Scenario: An acknowledged discovery is not listed

- **WHEN** a planning session has acknowledged a discovery-labelled Bead
- **THEN** discovery review no longer lists that Bead, regardless of its status

#### Scenario: Blocking discoveries are ordered first

- **WHEN** discovery review lists more than one pending discovery
- **THEN** discoveries whose Bead status is `blocked` appear before the others

### Requirement: Failed syncs are classified and carry bounded retry metadata

A sync that fails SHALL persist a failure record that classifies the failure as
`transient` or `permanent` and includes bounded retry metadata: the number of
consecutive failed attempts, a maximum attempt count, and the earliest time a
retry should be attempted. A failure classified as `permanent` SHALL NOT be
retried automatically. A failure classified as `transient` SHALL be eligible for
automatic retry only until the maximum attempt count is reached. A successful
sync SHALL clear the active failure record.

#### Scenario: A transient failure records retry metadata

- **WHEN** a sync fails for a transient reason such as lock contention
- **THEN** the failure record classifies the failure as `transient`
- **AND** the record includes the attempt count, the maximum attempt count, and the next eligible retry time

#### Scenario: A permanent failure is not retried automatically

- **WHEN** a sync fails because the invariant audit failed
- **THEN** the failure record classifies the failure as `permanent`
- **AND** the record does not schedule an automatic retry

#### Scenario: Retries stop at the attempt cap

- **WHEN** a transient failure has recurred for the maximum number of attempts
- **THEN** the failure record shows no further automatic retry is scheduled

#### Scenario: A successful sync clears the failure record

- **WHEN** a sync succeeds after a previous failure
- **THEN** the active failure record is removed
