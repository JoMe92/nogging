# workflow-commands Specification

## Purpose
TBD - created by archiving change planning-and-discovery-commands. Update Purpose after archive.

## Requirements

### Requirement: The `/plan` command runs a complete planning session

The project SHALL provide a `/plan` command that creates an isolated planning
worktree and a dedicated planning branch from current `develop`, injects the
Planning Agent persona there, and drives one planning session in a fixed order:
acquire the planning lock, review pending discoveries, hold the design dialogue,
author or revise the OpenSpec change, validate it, commit the `openspec/`
changes as the `planning` writer, materialize its Beads, integrate the committed
planning branch into `develop`, and release the planning lock. The command SHALL
NOT perform execution work, write planning artifacts in the caller's shared
checkout, force a planning lock that another session holds, or remove a dirty
or unintegrated planning worktree.

#### Scenario: A planning session uses its own worktree

- **WHEN** `/plan` is invoked with no planning lock held
- **THEN** a dedicated planning worktree and branch from current `develop` are
  created before any `openspec/` file is written
- **AND** the pending discoveries are reviewed before the change is authored
- **AND** the planning lock is acquired only for that planning session

#### Scenario: A planning session follows the prescribed order

- **WHEN** planning artifacts are ready
- **THEN** the change is validated and committed before its Beads are materialized
- **AND** the committed planning branch is integrated into `develop` before a
  clean planning worktree is eligible for removal
- **AND** the planning lock is released at the end of the session

#### Scenario: The planning lock is already held

- **WHEN** `/plan` is invoked and `.specforge/locks/planning.lock` is held by another session
- **THEN** the command reports the lock holder and stops
- **AND** it does not force or overwrite the lock

#### Scenario: An orphaned Bead halts the session

- **WHEN** during a `/plan` session an active Bead is found with no matching task mapping
- **THEN** the session stops and asks the Product Owner to resolve the orphan explicitly
- **AND** the Bead is not deleted automatically

### Requirement: The `/discovery-review` command triages discoveries without the planning lock

The project SHALL provide a `/discovery-review` command that lists every pending
discovery with blocking discoveries first and offers, per discovery, to carry it
into a planning session, acknowledge it so it stops being surfaced, or leave it
pending. The command SHALL NOT acquire the planning lock and SHALL NOT write any
file under `openspec/`.

#### Scenario: Pending discoveries are shown blocking-first

- **WHEN** `/discovery-review` is invoked and one or more discoveries are pending
- **THEN** the discoveries are listed with their human-readable notes
- **AND** discoveries whose Bead status is `blocked` appear before the others

#### Scenario: Review does not enter planning mode

- **WHEN** `/discovery-review` is invoked
- **THEN** no planning lock is acquired
- **AND** no file under `openspec/` is created or modified

#### Scenario: A discovery is acknowledged

- **WHEN** the operator chooses to acknowledge a discovery during `/discovery-review`
- **THEN** the discovery is recorded as acknowledged through the acknowledgement mechanism
- **AND** a subsequent `/discovery-review` no longer lists that discovery

### Requirement: The `/sync-now` command forces an immediate reconciliation

The project SHALL provide a `/sync-now` command that triggers a reconciliation
pass immediately rather than waiting for the timer. When a resident sync daemon
is running it SHALL be signalled to reconcile; otherwise a reconciliation pass
SHALL be run directly. When the sync lock is already held, the command SHALL
report the contention and exit without retrying.

#### Scenario: No daemon is running

- **WHEN** `/sync-now` is invoked and no sync daemon PID file names a live process
- **THEN** a reconciliation pass is run directly
- **AND** the result of the pass is reported

#### Scenario: A daemon is running

- **WHEN** `/sync-now` is invoked and a sync daemon PID file names a live process
- **THEN** that process is signalled to reconcile now
- **AND** the command reports that the running daemon was triggered

#### Scenario: The sync lock is held

- **WHEN** `/sync-now` runs a reconciliation pass while the timer holds the sync lock
- **THEN** the command reports that the lock is held
- **AND** it exits without retrying
