## MODIFIED Requirements

### Requirement: Retired worktrees are cleaned up safely
The system SHALL provide a safe cleanup path for planning and implementation
worktrees after their branch has been integrated or is explicitly no longer
needed. Cleanup SHALL refuse to discard an uncommitted worktree or an
unintegrated branch without an explicit user-directed recovery decision.
Before it removes any file, cleanup SHALL also refuse a worktree that is in
use: when the worktree, a path under it or its Git directory is a mount point
in the caller's mount table, when the mount table cannot be read, when the
caller's current directory is inside it, or when another active supervised
session records it as its working directory. A refusal SHALL name the cause
and the next step, and SHALL leave the worktree, its branch and its record
unchanged.

#### Scenario: An integrated planning worktree is cleaned up
- **WHEN** a planning branch has been integrated into `develop` and its
  worktree is clean
- **THEN** the planning worktree and its retired branch can be removed

#### Scenario: Cleanup encounters unfinished work
- **WHEN** cleanup finds uncommitted changes or a branch that is not integrated
- **THEN** it reports the condition and leaves the worktree and branch intact

#### Scenario: Cleanup inside a sandbox that mounts the worktree
- **WHEN** cleanup runs in a process whose mount table lists the worktree or its Git directory
- **THEN** it refuses before any removal and names the stop-then-cleanup hand-off
- **AND** every tracked file, the branch and the record remain

#### Scenario: Cleanup of a live session's worktree
- **WHEN** another session in `starting`, `running` or `idle` records the worktree as its working directory
- **THEN** cleanup refuses and names `session stop` for that session

#### Scenario: A planner retires its own worktree
- **WHEN** the owning planner runs cleanup from the canonical checkout after `plan-end`, and nothing mounts the worktree
- **THEN** its own active session record does not block the removal
