## MODIFIED Requirements

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
- **AND** it does not create a planning worktree or force or overwrite the lock

#### Scenario: An orphaned Bead halts the session

- **WHEN** during a `/plan` session an active Bead is found with no matching task mapping
- **THEN** the session stops and asks the Product Owner to resolve the orphan explicitly
- **AND** the Bead is not deleted automatically

