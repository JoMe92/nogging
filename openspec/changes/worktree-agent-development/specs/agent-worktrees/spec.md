## Purpose

Defines isolated Git worktree lifecycles so concurrent planning and execution
agents can work safely on one host without sharing mutable working directories.

## ADDED Requirements

### Requirement: Planning runs in an isolated worktree
The system SHALL require each planning session to begin from the current
`develop` ref in a newly created Git worktree on a dedicated planning branch.
The planning branch SHALL be uniquely named, identify the planning run and its
subject, and not be shared with another active agent. Planning artifacts SHALL
be committed on that branch before it is integrated into `develop`.

#### Scenario: A planning request starts from develop
- **WHEN** an agent starts a planning session for a named change
- **THEN** it creates a dedicated worktree and planning branch from the current
  `develop` ref before writing planning artifacts

#### Scenario: Planning artifacts are isolated and integrated
- **WHEN** the planning session validates successfully
- **THEN** its artifacts are committed on the planning branch and that branch
  is integrated into `develop` before the planning worktree is cleaned up

### Requirement: Implementation runs in an isolated worktree
The system SHALL require an agent assigned an existing planned task to create a
dedicated implementation worktree and a conforming implementation branch from
its updated view of `develop`. An implementation agent SHALL work only in that
worktree and SHALL NOT commit implementation changes directly to the shared
`develop` checkout.

#### Scenario: An implementation assignment receives a fresh worktree
- **WHEN** an agent starts an assigned implementation task
- **THEN** it updates `develop`, creates a separate worktree and a branch that
  satisfies the project's branch convention, and performs the work there

#### Scenario: Concurrent agents are isolated
- **WHEN** two agents work on different planned tasks on the same host
- **THEN** each agent has a distinct worktree and branch and neither agent
  switches branches or writes files in the other's worktree

### Requirement: Implementation delivery uses reviewed pull requests
The system SHALL require a completed implementation branch to be delivered by a
pull request targeting `develop`. Before creating that pull request, the agent
SHALL commit only relevant changes and run applicable local validation. The
agent SHALL NOT merge its own implementation pull request.

#### Scenario: A ready implementation is proposed to develop
- **WHEN** an agent completes a planned task and local validation passes
- **THEN** it creates a pull request describing the plan/task, implementation,
  technical decisions, validation evidence, and known limitations, with
  `develop` as the base branch

#### Scenario: An implementation agent does not self-merge
- **WHEN** every required pull-request check passes
- **THEN** the agent leaves the pull request open for user review and does not
  merge it into `develop`

### Requirement: Agents repair pull-request CI before review handoff
After creating an implementation pull request, the agent SHALL wait at least
approximately five minutes before its first CI status inspection. It SHALL
inspect all required GitHub Actions checks; on failure it SHALL diagnose and
fix the failure in the same implementation worktree and branch, commit and
push the correction, and repeat until required checks pass. A green CI state
SHALL mean ready for user review, not permission to merge.

#### Scenario: A newly created pull request is given time to start CI
- **WHEN** an agent creates an implementation pull request
- **THEN** it waits approximately five minutes before first evaluating the
  pull request's GitHub Actions status

#### Scenario: A required check fails
- **WHEN** a required GitHub Actions check fails on the implementation pull request
- **THEN** the agent inspects the failure, fixes it on the same branch, pushes
  the fix, and rechecks CI until the required checks pass

#### Scenario: Green CI is handed to the user
- **WHEN** all required GitHub Actions checks pass
- **THEN** the agent reports the pull request ready for user review and stops
  before merge

### Requirement: Requested changes follow a proportional workflow
The system SHALL require an agent to classify user-requested pull-request
changes as small or large. For a small change that does not materially alter
scope or architecture, the agent SHALL create and resolve a Bead on the
existing implementation branch and restore green CI. For a large or uncertain
change, the agent SHALL start a new isolated planning session and SHALL NOT
implement it immediately on the existing branch.

#### Scenario: A small review change stays on the pull request branch
- **WHEN** the agent determines a requested review change is small
- **THEN** it records a Bead, applies and validates the change in the existing
  worktree and branch, pushes it, and restores green CI on the same pull request

#### Scenario: A large review change starts a new cycle
- **WHEN** the agent determines a requested review change materially expands
  scope, architecture, interfaces, or coordination needs
- **THEN** it starts a new planning worktree and branch instead of changing the
  existing implementation branch

### Requirement: Retired worktrees are cleaned up safely
The system SHALL provide a safe cleanup path for planning and implementation
worktrees after their branch has been integrated or is explicitly no longer
needed. Cleanup SHALL refuse to discard an uncommitted worktree or an
unintegrated branch without an explicit user-directed recovery decision.

#### Scenario: An integrated planning worktree is cleaned up
- **WHEN** a planning branch has been integrated into `develop` and its
  worktree is clean
- **THEN** the planning worktree and its retired branch can be removed

#### Scenario: Cleanup encounters unfinished work
- **WHEN** cleanup finds uncommitted changes or a branch that is not integrated
- **THEN** it reports the condition and leaves the worktree and branch intact

