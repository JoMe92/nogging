# tool-agnostic-write-boundary Specification

## Purpose
TBD - created by archiving change tool-agnostic-write-boundary. Update Purpose after archive.

## Requirements

### Requirement: An execution agent of any tool cannot persist an OpenSpec change

Outside a planning session, an execution agent — regardless of whether it runs
under Claude Code, Codex, or another tool — SHALL NOT be able to create, modify,
or delete a file under `openspec/changes/` or `openspec/specs/`. The block SHALL
be anchored in the filesystem or the OS sandbox, not only in a Claude
Code-specific hook. The mechanical sync writer and ordinary git branch
operations SHALL be unaffected.

#### Scenario: A launched execution session cannot write openspec/

- **WHEN** a supervised session is launched for an execution role (not a planning role) and no planning session is active
- **THEN** an attempt by that session to write a file under `openspec/changes/` or `openspec/specs/` fails
- **AND** the failure does not depend on which agent tool the session runs

#### Scenario: The mechanical sync writer still mirrors closures

- **WHEN** the boundary is closed and a mapped Bead is closed and the sync pass runs
- **THEN** the sync writer updates the change's `execution-log.md` and task checkbox and commits as the `sync` writer

#### Scenario: Git branch operations are unaffected

- **WHEN** the boundary is closed and an operator runs `git switch`, `git merge`, or `git checkout` between branches that differ under `openspec/`
- **THEN** the operation succeeds and updates the `openspec/` files

### Requirement: plan-begin opens the boundary and plan-end closes it

`scripts/specforge plan-begin` SHALL leave `openspec/changes/` and
`openspec/specs/` writable for the planning session. `scripts/specforge
plan-end` SHALL leave them not writable by an execution agent. A fresh
installation SHALL start with the boundary closed, so `openspec/` is not
writable by an execution agent until the first `plan-begin`.

#### Scenario: Planning session can write openspec/

- **WHEN** `plan-begin` has run and its planning lock is fresh
- **THEN** editing a file under `openspec/changes/` succeeds

#### Scenario: plan-end re-closes the boundary

- **WHEN** `plan-end` has run
- **THEN** a subsequent execution-agent write under `openspec/changes/` is blocked

#### Scenario: A fresh install starts closed

- **WHEN** SpecForge has just been installed and no `plan-begin` has run
- **THEN** an execution-agent write under `openspec/` is blocked

### Requirement: A stale planning lock does not permit OpenSpec writes

The pre-edit guard SHALL treat a `planning.lock` whose age exceeds
`planning_lock_ttl_seconds` as not conferring write permission, matching the
staleness rule the lock helper already applies. A closed boundary sentinel SHALL
block writes regardless of the planning lock's presence.

#### Scenario: Stale lock is ignored by the guard

- **WHEN** `.specforge/locks/planning.lock` exists but its `created_at` is older than `planning_lock_ttl_seconds`
- **THEN** an `openspec/` Edit/Write is blocked as if the lock were absent

#### Scenario: plan-end takes effect despite a lingering lock

- **WHEN** `plan-end` has closed the boundary
- **AND** a stale `planning.lock` is still on disk
- **THEN** an `openspec/` Edit/Write is still blocked

### Requirement: The boundary state is reported by doctor

`scripts/specforge doctor` SHALL report whether the OpenSpec write boundary is
open or closed, and SHALL name a stale planning lock as the reason when the
boundary is effectively closed but a planning lock is still present.

#### Scenario: doctor shows an open boundary during planning

- **WHEN** a planning session is active and `doctor` runs
- **THEN** its output states that the OpenSpec write boundary is open

#### Scenario: doctor shows a closed boundary otherwise

- **WHEN** no planning session is active and `doctor` runs
- **THEN** its output states that the OpenSpec write boundary is closed

#### Scenario: doctor flags a stale planning lock

- **WHEN** the boundary is closed but a `planning.lock` older than its TTL is present
- **THEN** `doctor` names the stale lock and suggests `plan-end --force`
