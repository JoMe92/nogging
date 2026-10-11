## MODIFIED Requirements

### Requirement: Planning runs in an isolated worktree
The system SHALL require each planning session to begin from the current
`develop` ref in a newly created Git worktree on a dedicated planning branch.
The planning branch SHALL be uniquely named, identify the planning run and its
subject, and not be shared with another active agent. Planning artifacts SHALL
be committed on that branch before it is integrated into `develop`. The
worktree SHALL carry the `planner` persona's commit identity (the
`commit-identity` capability), isolated from every other worktree.

#### Scenario: A planning request starts from develop
- **WHEN** an agent starts a planning session for a named change
- **THEN** it creates a dedicated worktree and planning branch from the current
  `develop` ref before writing planning artifacts

#### Scenario: Planning artifacts are isolated and integrated
- **WHEN** the planning session validates successfully
- **THEN** its artifacts are committed on the planning branch and that branch
  is integrated into `develop` before the planning worktree is cleaned up

#### Scenario: The planning worktree carries the Planner identity
- **WHEN** a planning worktree is allocated
- **THEN** its `user.name`/`user.email` are the `planner` persona's,
  isolated from every other worktree and the shared checkout

### Requirement: Implementation runs in an isolated worktree
The system SHALL require an agent assigned an existing planned task to create a
dedicated implementation worktree and a conforming implementation branch from
its updated view of `develop`. An implementation agent SHALL work only in that
worktree and SHALL NOT commit implementation changes directly to the shared
`develop` checkout. The worktree SHALL carry the `lead` persona's commit
identity (the `commit-identity` capability), isolated from every other
worktree.

#### Scenario: An implementation assignment receives a fresh worktree
- **WHEN** an agent starts an assigned implementation task
- **THEN** it updates `develop`, creates a separate worktree and a branch that
  satisfies the project's branch convention, and performs the work there

#### Scenario: Concurrent agents are isolated
- **WHEN** two agents work on different planned tasks on the same host
- **THEN** each agent has a distinct worktree and branch and neither agent
  switches branches or writes files in the other's worktree

#### Scenario: The implementation worktree carries the Lead identity
- **WHEN** an implementation worktree is allocated
- **THEN** its `user.name`/`user.email` are the `lead` persona's, isolated
  from every other worktree and the shared checkout
