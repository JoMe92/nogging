# tool-agnostic-write-boundary Specification

## Purpose

Defines planning-only OpenSpec write authority and its enforcement and diagnosis across supported agent runtimes.

## Requirements

### Requirement: An execution agent of any tool cannot persist an OpenSpec change

An execution agent — regardless of whether it runs
under Claude Code, Codex, or another tool — SHALL NOT be able to create, modify,
or delete a file under `openspec/changes/` or `openspec/specs/`. Another session holding a planning lock SHALL NOT grant an execution role write authority. The block SHALL
be anchored in the filesystem or the OS sandbox, not only in a Claude
Code-specific hook. The mechanical sync writer and ordinary git branch
operations SHALL be unaffected.

#### Scenario: A launched execution session cannot write openspec/

- **WHEN** a supervised session is launched for an execution role (not a planning role) including when a different planning session is active
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

### Requirement: A fenced Lead integrates upstream through the host-side broker

When `NOGG_OPENSPEC_FENCED=1`, `nogg worktree rebase` SHALL NOT run git against
the worktree itself. It SHALL send one request to the sandbox broker named by
`NOGG_TASK_DONE_SOCKET` with exactly the keys `action` (`rebase`), `checkout`
(an absolute path), `mode` (`start`, `continue` or `abort`) and `session`. The
broker SHALL validate `checkout` with the same registered-worktree-root check as
the task tick, run the same refusing engine as a direct call on the host side,
and return `ok`, a `status` of `done`, `up-to-date`, `paused` or `refused`, and
the output. The broker SHALL accept no path other than `checkout`, no command and
no replacement text, and the existing `{bead_id, checkout}` task-done request
SHALL be unchanged. `scripts/openspec-sandbox --contract` SHALL advertise a
`rebase-broker` feature. A broker that predates the action, or a fenced caller
with no broker, SHALL produce a message that names the unfenced hand-off command
and changes nothing.

#### Scenario: A fenced Lead rebases without writing openspec itself

- **WHEN** a fenced Lead runs `worktree rebase` and upstream touched `openspec/`
- **THEN** the host-side broker performs the rebase, the client ran no git
  mutation, and the Lead's tree is up to date and clean

#### Scenario: The broker rejects an open-ended request

- **WHEN** a request carries an extra key, a relative path, an unregistered
  checkout or a mode other than the three allowed
- **THEN** the broker returns an error and runs nothing

#### Scenario: An older broker is handled honestly

- **WHEN** the session's broker does not know the rebase action
- **THEN** the client exits 1 with the hand-off command and no file, ref or journal
  was written

### Requirement: A fenced session is stopped before a raw rebase damages the tree

`scripts/hooks/pre-rebase` SHALL exit non-zero before git touches the working tree
when `NOGG_OPENSPEC_FENCED=1` or `openspec/` is not writable and the diff between
`HEAD` and the rebase upstream touches `openspec/`, naming `nogg worktree rebase`
as the supported command. It SHALL allow every other rebase, including any rebase
by a caller that can write `openspec/`. `scripts/install-hooks` SHALL install it
and the payload manifest SHALL ship it. The `no-autonomous-claim` and
`autonomous` launch prompts SHALL tell a session not to integrate upstream with
`git rebase`, `git merge` or `git pull` while `openspec/` is read-only, to use
`./scripts/nogg worktree rebase`, and never to reset a dirty tree it did not make.

#### Scenario: A raw rebase is refused before any write

- **WHEN** a fenced session runs `git rebase origin/develop` and upstream changed
  `openspec/`
- **THEN** the hook exits 1, no file in the worktree changed and the message names
  the supported command

#### Scenario: A rebase that cannot hurt is allowed

- **WHEN** upstream did not change `openspec/`, or the caller can write it
- **THEN** the hook allows the rebase

#### Scenario: The prompts carry the rule

- **WHEN** a Lead is launched with either prompt
- **THEN** the prompt text names `worktree rebase` and forbids the raw commands
