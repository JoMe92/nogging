## ADDED Requirements

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
