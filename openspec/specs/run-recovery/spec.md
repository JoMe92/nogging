# run-recovery Specification

## Purpose

Defines diagnosis and safe resumption of interrupted planning and execution from durable repository and Beads state.

## Requirements

### Requirement: recover reports the state of an interrupted run

`scripts/specforge recover` SHALL, read-only and without mutating any Bead or
writing any file, report: lock freshness; every Bead that has a commit carrying
its ID token on the current branch but is not closed; every `in_progress` Bead
with an age classification; a change that has mapped Beads but an uncommitted or
uncommitted-into-git `tasks.md`; orphan Beads; session records whose tmux
session is gone; and the working-tree / mid-operation state. It SHALL exit
non-zero when any committed-but-open Bead, stale lock, orphan Bead,
materialized-but-uncommitted change, or crashed session record is present, and
zero otherwise.

#### Scenario: A committed-but-open Bead is surfaced

- **WHEN** a commit on the current branch carries `[SPEC-x]` and `SPEC-x` is not closed
- **AND** `recover` runs
- **THEN** it lists `SPEC-x` as committed-but-open with the commit SHA
- **AND** `recover` exits non-zero

#### Scenario: A clean repository passes

- **WHEN** there is no committed-but-open Bead, no stale lock, no orphan, no materialized-but-uncommitted change, and no crashed session
- **THEN** `recover` exits zero

#### Scenario: recover does not mutate anything

- **WHEN** `recover` runs against any repository state
- **THEN** no Bead status, note, or label changes
- **AND** no file under `.specforge/` or `openspec/` is written

### Requirement: The audit distinguishes warnings from failures

`scripts/specforge validate` SHALL return warnings separately from failures. A
Bead with a commit carrying its ID token but a non-closed status SHALL be a
warning, not a failure, so the mechanical sync still mirrors the Beads that are
closed. `doctor` SHALL show warnings distinctly from failures.

#### Scenario: A limbo Bead does not break sync

- **WHEN** one Bead is committed-but-open and another mapped Bead is closed
- **AND** the mechanical sync runs
- **THEN** the closed Bead is mirrored
- **AND** the sync does not fail

#### Scenario: doctor shows the warning

- **WHEN** a committed-but-open Bead exists and `doctor` runs
- **THEN** `doctor` reports it as a warning, not a failure

### Requirement: The planning flow commits the spec before materialization

The canonical planning flow SHALL commit the OpenSpec change before
materializing its Beads, so a crash between the two never leaves Beads without a
committed spec. `scripts/specforge materialize` SHALL keep a journal of which
tasks it has created for a change, and remove it on clean completion, so a
resumed materialization knows what is left.

#### Scenario: The documented flow order

- **WHEN** the planning flow is described in the operating model, `AGENTS.md`, and the `/plan` command
- **THEN** every description places the commit before `materialize`

#### Scenario: A resumed materialization completes without duplicates

- **WHEN** `materialize` is interrupted after creating some but not all of a change's Beads
- **AND** it is run again
- **THEN** it creates only the still-missing Beads
- **AND** the journal is removed once every task has a Bead

### Requirement: A resumption protocol precedes work selection

`AGENTS.md` SHALL instruct every session — fresh, resumed, or after a tool
switch — to run `scripts/specforge recover` and resolve what it reports, using a
documented playbook, before selecting work with `bd ready`. The playbook SHALL
state that a committed-but-open Bead's work is already done and must be verified
and closed, not re-implemented.

#### Scenario: The protocol is stated tool-neutrally

- **WHEN** `AGENTS.md` is read by any agent tool
- **THEN** it describes running `recover` before `bd ready`
- **AND** `docs/failure-recovery.md` carries a per-finding playbook

### Requirement: Crashed session records can be reaped

`scripts/nogg` SHALL provide a way to move every session record in an active
state whose backend session no longer exists to a terminal `failed` state, so
that `session cleanup` can retire it. Each record's liveness SHALL be judged by
that record's own session backend.

A live session record SHALL NOT be affected. A record whose backend's liveness
cannot be determined SHALL NOT be affected, and the reap SHALL report it in a
note.

#### Scenario: A vanished session is reaped and cleaned up

- **WHEN** a session record is `running` but its backend session is gone
- **AND** the reap operation runs
- **THEN** the record's state becomes `failed`
- **AND** a subsequent `session cleanup` retires it

#### Scenario: A live session is left alone

- **WHEN** a session record is `running` and its backend session exists
- **AND** the reap operation runs
- **THEN** the record is unchanged

#### Scenario: Unknown liveness is left alone

- **WHEN** a herdr session record is `running` and the herdr CLI fails unexpectedly
- **AND** the reap operation runs
- **THEN** the record is unchanged and a note reports the unknown liveness

### Requirement: doctor's tool-presence checks reflect the invoking process's PATH

`scripts/specforge doctor` SHALL determine whether `git`, `python3`, `bd`,
`dolt`, and `codex` are available by resolving each name against the
invoking process's own `PATH` directly (e.g. `shutil.which`), and SHALL NOT
re-derive `PATH` through a login shell or any other mechanism that can reset
it from system profile scripts.

#### Scenario: A tool on the caller's PATH is detected even when a login shell would hide it

- **WHEN** a tool is available via the invoking process's `PATH`, but a login
  shell's profile scripts would reset `PATH` and hide it
- **THEN** `doctor` still reports the tool as present

### Requirement: doctor reports a change ready to archive

`doctor` SHALL report, as a NOTE, every live (non-archived) change under
`openspec/changes/` whose every mapped Bead is closed, determined using the
same closed-inclusive Beads enumeration the sync and materialize mechanisms
use rather than a closed-excluding listing. This NOTE SHALL NOT fail
`doctor` or change its exit code, matching every other advisory NOTE `doctor`
already prints.

#### Scenario: A fully-closed change is surfaced

- **WHEN** every Bead mapped to a live change's tasks is closed
- **AND** `doctor` runs
- **THEN** it prints a NOTE naming that change as ready to archive
- **AND** `doctor`'s exit code is unchanged

#### Scenario: A partially-closed change is not surfaced

- **WHEN** a live change has at least one open or in-progress mapped Bead
- **AND** `doctor` runs
- **THEN** it does not report that change as ready to archive

### Requirement: doctor reports unpushed local Dolt state under multi-machine mode

When `multi_machine` is enabled and the local Dolt history has commits not
present on the configured remote, `doctor` SHALL report a NOTE naming how
many. This NOTE SHALL NOT fail `doctor` or change its exit code, and SHALL
NOT appear when `multi_machine` is disabled.

#### Scenario: Unpushed Dolt state is surfaced

- **WHEN** `multi_machine` is enabled
- **AND** local Dolt has commits the configured remote does not have
- **AND** `doctor` runs
- **THEN** it prints a NOTE naming the count
- **AND** `doctor`'s exit code is unchanged

#### Scenario: Nothing to report when fully pushed

- **WHEN** `multi_machine` is enabled
- **AND** local Dolt has no commits the remote lacks
- **AND** `doctor` runs
- **THEN** it prints no unpushed-state NOTE

#### Scenario: The check is silent when the mode is off

- **WHEN** `multi_machine` is disabled
- **AND** `doctor` runs
- **THEN** it prints no unpushed-state NOTE regardless of local Dolt state

### Requirement: Partial reconciliation is visibly degraded

A partial sync SHALL expose affected changes, Bead IDs and reasons with a documented nonzero degraded result, SHALL preserve the last completely successful timestamp, and SHALL let doctor distinguish last complete success from last partial pass.

#### Scenario: Partial pass after an earlier success

- **WHEN** only some valid changes reconcile
- **THEN** doctor shows skipped work and both timestamps without describing the whole repository as healthy

### Requirement: doctor and recover report a half-applied checkout

A read-only classifier SHALL examine each recorded worktree (and the current
checkout) and label it `clean`, `operation-in-progress`, `half-applied`, `mixed` or
`dirty`. `half-applied` SHALL mean no git operation is in progress and every
dirty path is byte-identical to `origin/develop` (a deleted path is absent
there); `mixed` SHALL mean some dirty paths are and others are not; `dirty` SHALL
mean none are. The label SHALL come from byte equality, never from a count of
modified files. `recover` SHALL raise attention for `half-applied` and `mixed`,
and `doctor` SHALL print a `NOTE`. For both, the output SHALL list the
reproducible paths, list every other path as untouched own work, and print a
path-scoped recovery command (`git restore --source=HEAD --staged --worktree --`
for tracked paths and `git clean -f --` for untracked ones, plus `nogg worktree
repair <record>`), and SHALL NOT print `reset --hard` or a directory-wide clean.
A plain `dirty` tree SHALL NOT be reported as a problem. The classifier SHALL
write nothing.

#### Scenario: The #241 state is detected

- **WHEN** upstream files were written into a worktree with `HEAD` unchanged and
  no rebase state
- **THEN** `recover` exits non-zero naming the worktree as half-applied and
  `doctor` prints a NOTE with the path-scoped hint

#### Scenario: Real work is never labelled as damage

- **WHEN** a worktree holds only edits that differ from upstream
- **THEN** it is `dirty`, neither command reports it and no recovery command is
  printed

#### Scenario: Mixed state protects the Lead's files

- **WHEN** reproducible upstream paths and the Lead's own edits coexist
- **THEN** only the reproducible paths appear in the hint and the others are
  listed as untouched

### Requirement: A stale rebase journal is reported with its backup

`recover` and `doctor` SHALL report a rebase journal left at `running` with no git
operation in progress, or at `paused` with no `rebase-merge` directory, naming the
journal, the branch and the backup ref that holds the previous tip, and SHALL NOT
delete the journal or the ref.

#### Scenario: A crash during rebase is visible

- **WHEN** the engine crashed after writing its journal and before git changed
  anything
- **THEN** `recover` names the branch and the backup ref and exits non-zero
