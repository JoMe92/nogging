## ADDED Requirements

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
