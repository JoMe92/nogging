## MODIFIED Requirements

### Requirement: Planning lock cleanup respects its owning supervised session

A planning session SHALL own its lock acquisition and release. Stop, cleanup and recovery SHALL refuse to release a different live owner lock, SHALL surface interrupted ownership, and SHALL preserve dirty or unintegrated planning worktrees. Stopping the owning planning session SHALL wait, within the stop grace period, for the owner process to exit and SHALL then release that session's lock without `--force`. A lock kept for a still-live owner, and recovery's report of an interrupted owner that still has a session record, SHALL name `session stop <name>` as the release step.

#### Scenario: Unrelated stop

- **WHEN** an execution session stops while a planner holds its lock
- **THEN** the planning lock remains held

#### Scenario: Interrupted planner

- **WHEN** the owning planner dies before plan-end
- **THEN** recovery names the owner and provides a safe closed-boundary recovery path

#### Scenario: Stopping the owning planner

- **WHEN** an operator stops the planning session that owns the lock and its process exits within the grace period
- **THEN** the lock is released and the boundary closed without `plan-end --force`

#### Scenario: Owner outlives the grace period

- **WHEN** the owner process is still live after the grace period
- **THEN** the lock is kept and the message names `session stop <name>` to rerun once it has exited
