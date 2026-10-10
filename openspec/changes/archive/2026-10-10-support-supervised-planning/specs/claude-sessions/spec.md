## ADDED Requirements

### Requirement: Planning is a supervised Bead-optional role

Session launch SHALL accept --role planning with a planning identifier and description, SHALL allocate a dedicated planning worktree, and SHALL record the true role. Planning SHALL NOT require or claim a placeholder execution Bead. Bare launch SHALL remain idle and perform no planning-lock or Beads mutation; role-specific kickoff SHALL direct the planner to acquire its own canonical planning lock before writing.

#### Scenario: Launch before tasks exist

- **WHEN** an operator launches a named planning session with no Bead
- **THEN** a tracked planning session starts in its dedicated worktree and names its required kickoff

#### Scenario: Planning lock contention

- **WHEN** two planners receive kickoff concurrently
- **THEN** only the lock-owning planner may begin spec writes; the other reports the owner

### Requirement: Planning lock cleanup respects its owning supervised session

A planning session SHALL own its lock acquisition and release. Stop, cleanup and recovery SHALL refuse to release a different live owner lock, SHALL surface interrupted ownership, and SHALL preserve dirty or unintegrated planning worktrees.

#### Scenario: Unrelated stop

- **WHEN** an execution session stops while a planner holds its lock
- **THEN** the planning lock remains held

#### Scenario: Interrupted planner

- **WHEN** the owning planner dies before plan-end
- **THEN** recovery names the owner and provides a safe closed-boundary recovery path
