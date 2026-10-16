## MODIFIED Requirements

### Requirement: The `/plan` command runs a complete planning session

The project SHALL provide a `/plan` command that creates an isolated planning
worktree and a dedicated planning branch from current `develop`, injects the
Planning Agent persona there, and drives one planning session in a fixed order:
acquire the planning lock, review pending discoveries, archive any change
`doctor` reports as ready (merging its `specs/` deltas and validating before
any new change content is authored), hold the design dialogue, author or
revise the OpenSpec change, validate it, commit the `openspec/` changes as the
`planning` writer, materialize its Beads, integrate the committed planning
branch into `develop`, release the planning lock with `plan-end` from the
planning worktree, and only then retire the clean, integrated planning
worktree from the surviving canonical checkout. When that retirement is
refused, the session SHALL report the hand-off (stop the session, then run
the same cleanup from the canonical checkout) instead of retrying, forcing or
deleting files. The command SHALL NOT perform execution work, write planning
artifacts in the caller's shared checkout, force a planning lock that another
session holds, or remove a dirty or unintegrated planning worktree.

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
- **AND** the planning lock is released with `plan-end` from the planning
  worktree before that worktree is retired

#### Scenario: A sandboxed planner hands off retirement

- **WHEN** a planner has run `plan-end` and `worktree cleanup` refuses because
  the worktree is mounted into the planner's sandbox
- **THEN** the planner reports the stop-then-cleanup hand-off and stops
- **AND** no file of the worktree has been removed

#### Scenario: A completed change is archived before new content is authored

- **WHEN** `/plan` is invoked and `doctor` reports a change ready to archive
- **THEN** that change is archived — its `specs/` deltas merged and the
  archive validated — before any new `openspec/` content is written for this
  session's own change

#### Scenario: Nothing is ready to archive

- **WHEN** `/plan` is invoked and `doctor` reports no change ready to archive
- **THEN** the session proceeds directly to the design dialogue with no
  archive step performed

#### Scenario: The planning lock is already held

- **WHEN** `/plan` is invoked and the canonical `.nogging/locks/planning.lock` is held by another session
- **THEN** the command reports the lock holder and stops
- **AND** it does not force or overwrite the lock

#### Scenario: An orphaned Bead halts the session

- **WHEN** during a `/plan` session an active Bead is found with no matching task mapping
- **THEN** the session stops and asks the Product Owner to resolve the orphan explicitly
- **AND** the Bead is not deleted automatically

## ADDED Requirements

### Requirement: Planning instructions avoid interactive and host-owned commands

Every planning surface (the planning launch prompt, the `/plan` command for
each runtime, the Antigravity plan skill and the orchestrator prompt) SHALL
name the change in its strict OpenSpec validation and SHALL disable
interactive prompts (`openspec validate <change> --strict
--no-interactive`). None of them SHALL instruct a bare `openspec validate`.
The planning, autonomous and no-autonomous-claim launch prompts SHALL state
that the shared Dolt server is host-owned: a session never starts, stops or
restarts it, and reports the exact error when `bd` cannot reach it.

#### Scenario: Validation never waits for input

- **WHEN** a planning surface instructs strict OpenSpec validation
- **THEN** the instruction names the change and passes `--no-interactive`

#### Scenario: Unreachable Dolt server

- **WHEN** a supervised session's `bd` call reports that the Dolt server is unreachable
- **THEN** its launch prompt directs it to stop and report the error rather than start the server
