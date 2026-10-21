# agent-worktrees Specification

## Purpose

Defines isolated Git worktree lifecycles so concurrent planning and execution
agents can work safely on one host without sharing mutable working directories.

## Requirements

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

### Requirement: Recovery resolves planned tasks from the integration ref
The system SHALL make recovery and diagnostic task mapping for agent work use
the current `develop` integration ref when the caller is in a shared checkout
that does not contain a live planned change. It SHALL not report a Bead mapped
to a task present on `develop` as orphaned solely because the caller is on
`main` or another non-execution branch. If `develop` is unavailable or the
mapping is absent there as well, it SHALL retain the existing actionable orphan
report.

#### Scenario: Shared main checkout sees a develop-only planned task
- **WHEN** a Bead maps to a live task on `develop`
- **AND** `recover` runs from a shared checkout on `main` that lacks that task
- **THEN** recovery does not report that Bead as orphaned

#### Scenario: No integration-ref mapping exists
- **WHEN** a Bead's task mapping is absent from both the caller's checkout and
  `develop`
- **THEN** recovery reports the Bead as orphaned with its existing recovery guidance

### Requirement: A Claude Code session enters its allocated worktree without a blocking tool prompt

An autonomous Claude Code session that allocates an implementation or planning
worktree via `scripts/nogg worktree implement` / `worktree plan` SHALL be
instructed to switch into that worktree with a plain shell `cd`, not with the
`EnterWorktree` tool. Claude Code's own relocation-approval prompt for
`EnterWorktree` cannot be suppressed by any permission rule or "don't ask
again" selection — only `bypassPermissions` mode skips it — and Nogging's
`trusted` profile deliberately does not grant `bypassPermissions`, so an
unattended session that used `EnterWorktree` would block indefinitely on that
prompt with no operator present to answer it.

#### Scenario: An autonomous session is told to cd, not EnterWorktree

- **WHEN** the `autonomous` launch prompt instructs a session to allocate and
  enter an implementation or planning worktree
- **THEN** it instructs the session to `cd` into that worktree via Bash
- **AND** it instructs the session not to use the `EnterWorktree` tool for
  that worktree

#### Scenario: A full-access Lead session does not block entering its worktree

- **WHEN** a `--full-access` Lead session allocates its implementation
  worktree and switches into it per the `autonomous` prompt's instruction
- **THEN** no interactive relocation-approval prompt blocks the session

### Requirement: An implementation worktree is rebased onto origin/develop by the writer side

The system SHALL provide `nogg worktree rebase [<record>]`, which fetches
`origin develop` and rebases a registered implementation worktree's branch onto
`origin/develop` in a process that can write `openspec/`. The record SHALL be a
`kind: implementation` record read from the canonical state directory, defaulting
to the record whose path is the caller's checkout root. A planning record SHALL be
refused. Before any write the command SHALL write a durable journal and create a
backup ref `refs/nogg/rebase-backup/<branch>/<stamp>` at the previous tip. Commits
it replays SHALL keep the worktree's persona identity. When `origin/develop` is
already an ancestor of `HEAD` it SHALL report that and write nothing. It SHALL
never push, resolve a conflict, stash, or run `reset --hard`, `checkout --`,
`clean` or `--force` itself.

#### Scenario: A Lead's branch is brought up to date across an openspec change

- **WHEN** upstream `develop` gained commits touching code, a `tasks.md` tick and
  an archive rename, and the writer side runs `worktree rebase` for the Lead's
  clean worktree
- **THEN** the branch is replayed onto `origin/develop`, the tree is clean with no
  operation state, the Lead's commits keep the `lead` identity, and the journal is
  removed

#### Scenario: The previous tip stays recoverable

- **WHEN** a rebase finishes or is aborted
- **THEN** `refs/nogg/rebase-backup/<branch>/<stamp>` names the exact previous tip
  and the output prints the command to return to it without running it

#### Scenario: Nothing to do

- **WHEN** the branch already contains `origin/develop`
- **THEN** the command prints `already up to date`, exits 0 and writes no journal
  or ref

#### Scenario: A planning worktree is not rebased this way

- **WHEN** the command is given a planning record
- **THEN** it refuses naming the reason and changes nothing

### Requirement: The rebase refuses anything that could lose or misattribute work

Before any write, `nogg worktree rebase` SHALL refuse, naming the cause and
changing nothing, when: the record is missing, not `allocated`, or its worktree is
not registered; `HEAD` is detached, not on the recorded branch, or on `main` or
`develop`; a merge, cherry-pick, bisect or an unrelated rebase is in progress; the
working tree is not completely clean, untracked files included; a live supervised
session other than the requester records the worktree as its working directory
(unless `--allow-live-session` is given); the branch contains merge commits not in
`origin/develop`; or the fetch fails. It SHALL NOT stash. When the dirty tree is a
half-applied checkout it SHALL print the recovery hint of the run-recovery
capability.

#### Scenario: A dirty tree is never rebased over

- **WHEN** the worktree has an uncommitted edit or an untracked file
- **THEN** the command exits 1 naming the paths, the branch tip and tree are
  unchanged and no stash exists

#### Scenario: Another Lead's live worktree is protected

- **WHEN** a live session other than the requester works in the target worktree
- **THEN** the command refuses unless `--allow-live-session` was passed

#### Scenario: A failed fetch changes nothing

- **WHEN** `git fetch origin develop` fails
- **THEN** the command exits 1 before writing a journal, a backup ref or any file

### Requirement: Rebase conflicts never strand a Lead

When replay conflicts, the command SHALL decide by path. A conflict on any path
under `openspec/` SHALL abort the whole rebase, verify the tree equals the
previous state, name the paths and exit 1. A conflict only outside `openspec/`
SHALL leave a valid paused git rebase, record the journal as `paused`, list the
conflicted paths and exit 3. `nogg worktree rebase --continue` SHALL continue and
`--abort` SHALL abort that paused rebase on the writer side, and either SHALL
refuse and change nothing when no Nogg rebase is paused. A continue that hits a
new conflict SHALL pause again.

#### Scenario: An openspec conflict aborts cleanly

- **WHEN** the Lead's replayed commit and upstream both change the same line of an
  `openspec/` file
- **THEN** the tree returns to the exact previous `HEAD` and clean state, the
  conflicting path is named and the exit code is 1

#### Scenario: A code conflict is resolved by the Lead

- **WHEN** the conflict is only in a source file
- **THEN** the exit code is 3 with a real paused rebase, and after the Lead edits
  and stages the file `worktree rebase --continue` finishes the rebase

#### Scenario: Abort restores the previous state

- **WHEN** a paused rebase is ended with `--abort`
- **THEN** `HEAD` and the tree equal the pre-rebase state and the journal is gone

#### Scenario: Continue with nothing paused

- **WHEN** `--continue` or `--abort` runs with no paused Nogg rebase
- **THEN** it refuses and changes nothing

### Requirement: A half-applied checkout is repaired without discarding other work

The system SHALL provide `nogg worktree repair <record> [--apply]`. Without
`--apply` it SHALL print exactly which paths it would restore and which it would
leave. With `--apply` it SHALL first write a snapshot commit of the entire dirty
state, untracked files included, to `refs/nogg/repair-backup/<branch>/<stamp>`
without changing the working tree, then restore only paths whose worktree bytes
equal the blob at `origin/develop` (or whose deletion matches upstream), using
path-scoped commands. It SHALL refuse while a git operation is in progress or a
live foreign session works there, SHALL leave every other path untouched, SHALL
NOT run `reset --hard` or a directory-wide `clean`, and, from a fenced caller,
SHALL refuse any `openspec/` path.

#### Scenario: The #241 state is repaired

- **WHEN** upstream files were written into a worktree with `HEAD` unchanged and no
  rebase state, and `repair --apply` runs
- **THEN** exactly those paths return to the `HEAD` state, the tree is clean and
  the snapshot ref holds the previous dirty state

#### Scenario: The Lead's own work survives

- **WHEN** the same tree also holds an edited file and an untracked file that are
  not byte-identical to upstream
- **THEN** both survive byte for byte and are reported as untouched

#### Scenario: Dry run changes nothing

- **WHEN** `repair` runs without `--apply`
- **THEN** it only prints the plan and writes no ref or file
