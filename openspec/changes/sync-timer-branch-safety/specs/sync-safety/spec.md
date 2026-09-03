## ADDED Requirements

### Requirement: The timer-driven sync refuses an unsafe repository state

A `sync` invoked by the timer SHALL NOT mirror or commit, and SHALL instead
print why and return successfully, when any of the following holds: a fresh
planning lock is held; a merge, rebase, cherry-pick, or bisect is in progress;
`HEAD` is detached; or `HEAD` is on a branch listed in the configured protected
set. A skipped tick SHALL NOT be recorded as a failure and SHALL NOT change the
last-success record, so the next tick retries.

#### Scenario: A merge in progress is not disturbed

- **WHEN** a merge is in progress in the working tree and the timer runs `sync`
- **THEN** `sync` makes no commit and no `openspec/` change
- **AND** it prints that it skipped because a merge is in progress
- **AND** no failure record is written

#### Scenario: The timer does not commit on a protected branch

- **WHEN** `HEAD` is on `develop` (a protected branch) and the timer runs `sync`
- **THEN** `sync` makes no commit
- **AND** the last-success record is unchanged

#### Scenario: A held planning lock pauses the timer

- **WHEN** a fresh planning lock is held and the timer runs `sync`
- **THEN** `sync` skips and records no failure

#### Scenario: A skipped tick retries

- **WHEN** a tick skips for a transient reason and the reason later clears
- **THEN** a subsequent tick mirrors the outstanding closures normally

### Requirement: An operator-invoked sync may run on a protected branch

`sync --now` SHALL proceed on a protected branch, since the operator asked for
it explicitly, but SHALL still refuse when a merge, rebase, cherry-pick, or
bisect is in progress or a planning lock is held, and SHALL say what must be
finished first.

#### Scenario: sync --now catches up on develop

- **WHEN** `HEAD` is on `develop` and the operator runs `sync --now`
- **THEN** the reconciliation pass runs and mirrors outstanding closures

#### Scenario: sync --now still refuses a mid-merge

- **WHEN** a merge is in progress and the operator runs `sync --now`
- **THEN** it does not run the pass
- **AND** it tells the operator to finish the merge first

### Requirement: The sync records and surfaces the branch it mirrors on

A successful sync SHALL record the branch it committed on. When that branch
differs from the previously recorded one, the sync SHALL print a one-line note.
When a tick has skipped, `scripts/specforge doctor` SHALL report the skip and
its reason.

#### Scenario: A branch change is noted

- **WHEN** a successful sync commits on a branch different from the last recorded one
- **THEN** it prints a note naming the new and the previous branch
- **AND** the recorded branch is updated

#### Scenario: doctor surfaces a stalled mirror

- **WHEN** the most recent tick skipped and `doctor` runs
- **THEN** `doctor` reports that the last sync skipped and why
