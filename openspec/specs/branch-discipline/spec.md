# branch-discipline Specification

## Purpose
TBD - created by archiving change enforce-conventional-branching. Update Purpose after archive.

## Requirements

### Requirement: Working branches follow a named convention

The project SHALL define a branch-naming convention in which a working branch is
named `<type>/<slug>`, where `<type>` is a Conventional Commit type or `plan`.
A branch that advances an OpenSpec change SHALL use that change's
`openspec/changes/<slug>/` directory name as its `<slug>`. Work not scoped to a
single change SHALL use `chore/<topic>` or `plan/<topic>` with a free topic
slug. Planning branches MAY instead use the hierarchical form
`plan/<planning-id>/<description>`, where both path segments are non-empty
kebab-case slugs; this form identifies an isolated planning run and its subject.
The branches `main` and `develop` SHALL be exempt.

#### Scenario: Change branch matches a change directory

- **WHEN** a branch is named `feat/dark-mode-toggle`
- **AND** `openspec/changes/dark-mode-toggle/` exists
- **THEN** the branch satisfies the convention

#### Scenario: Change branch with no matching change is rejected

- **WHEN** a branch is named `feat/some-idea`
- **AND** no `openspec/changes/some-idea/` directory exists
- **THEN** the branch violates the convention

#### Scenario: Hierarchical planning branch is accepted

- **WHEN** a branch is named `plan/agent-runtime/parallel-execution`
- **THEN** the branch satisfies the convention without requiring an existing
  change directory

#### Scenario: Malformed hierarchical planning branch is rejected

- **WHEN** a branch is named `plan/agent-runtime/`
- **THEN** the branch violates the convention

#### Scenario: Unknown type is rejected

- **WHEN** a branch is named `wip/dark-mode-toggle`
- **THEN** the branch violates the convention

#### Scenario: Topic branch needs no change directory

- **WHEN** a branch is named `chore/upgrade-ci`
- **THEN** the branch satisfies the convention regardless of `openspec/changes/`

#### Scenario: Protected branches are exempt

- **WHEN** the branch is `main` or `develop`
- **THEN** the convention check does not apply

### Requirement: CI enforces branch and commit discipline on pull requests

On every pull request, CI SHALL verify that the head branch satisfies the
branch-naming convention and that every non-merge commit the pull request
introduces satisfies the commit-message rule enforced by
`scripts/hooks/commit-msg`: a Conventional Commit subject containing a real
Beads issue ID token, unless the commit is a planning or sync writer commit. A
violation SHALL fail the pull request with a message identifying the offending
branch, or the offending commit by SHA and subject. The commit-message rule
SHALL have a single implementation that CI reuses rather than re-encodes.

#### Scenario: Non-conforming branch fails

- **WHEN** a pull request's head branch does not satisfy the convention
- **THEN** the CI invariant job fails
- **AND** the message names the branch and the expected form

#### Scenario: Commit without a Beads ID fails

- **WHEN** a pull request introduces a non-merge commit whose subject is a
  Conventional Commit but contains no Beads issue ID token
- **AND** the commit is not a writer commit
- **THEN** the job fails
- **AND** the message names the commit SHA and subject

#### Scenario: Conforming pull request passes

- **WHEN** the head branch conforms
- **AND** every introduced non-merge commit satisfies the commit-message rule
- **THEN** the invariant job passes

#### Scenario: Merge commits are ignored

- **WHEN** a pull request's commit range contains merge commits
- **THEN** those merge commits are not subject to the commit-message rule

### Requirement: Planning and sync commits are identified by a durable marker

A planning or sync commit SHALL be identifiable from the commit message alone,
via a `SpecForge-Writer: planning` or `SpecForge-Writer: sync` trailer, so the
writer exemption to the commit-message rule is applied identically by the local
`commit-msg` hook and by CI. The pre-existing `SPECFORGE_WRITER` environment
variable SHALL continue to exempt a commit for local use. A Conventional Commit
subject SHALL remain mandatory for a writer commit.

#### Scenario: Trailer exempts a planning commit

- **WHEN** a commit message has a Conventional subject, a `SpecForge-Writer:
  planning` trailer, and no Beads ID token
- **THEN** the commit-message rule accepts it

#### Scenario: Trailer still requires a Conventional subject

- **WHEN** a commit message has a `SpecForge-Writer: planning` trailer but a
  non-Conventional subject
- **THEN** the commit-message rule rejects it

#### Scenario: Invalid writer value does not exempt

- **WHEN** a commit message carries `SpecForge-Writer: something-else` and no
  Beads ID token
- **THEN** the commit-message rule rejects it

#### Scenario: Environment variable still works locally

- **WHEN** a commit is made with `SPECFORGE_WRITER=sync` in the environment and
  no Beads ID token
- **THEN** the local `commit-msg` hook accepts it

### Requirement: Local pre-push check mirrors the branch convention

`scripts/install-hooks` SHALL install a `pre-push` hook that rejects a push from
a branch whose name does not satisfy the branch-naming convention, with the
same message CI uses. Where `core.hooksPath` diverts Git away from `.git/hooks`,
this hook is advisory and CI remains authoritative.

#### Scenario: Bad branch name blocks push

- **WHEN** `git push` runs from a branch that violates the convention
- **AND** `.git/hooks` is active
- **THEN** the push is blocked with an actionable message

#### Scenario: Conforming branch pushes

- **WHEN** `git push` runs from a branch that satisfies the convention
- **THEN** the pre-push hook allows the push

#### Scenario: Hook is installed by install-hooks

- **WHEN** `scripts/install-hooks` runs
- **THEN** a `pre-push` hook is present in `.git/hooks`
