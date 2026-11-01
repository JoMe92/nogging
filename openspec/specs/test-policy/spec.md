# test-policy Specification

## Purpose
Define the test policy: test sizes, which suites run when, and how test weakening is recorded.

## Requirements

### Requirement: A short generic test policy ships with every install

The repository SHALL contain `docs/testing-policy.md`, and `init` and `update` SHALL
install it as `docs/nogging/testing-policy.md` through the reference-docs class. The
policy SHALL state what to always test (spec scenarios, one red-first regression test
per bug fix, error paths, contracts at module and API boundaries), what not to test
(framework or library behaviour, trivia, source text, the same behaviour at several
levels, impossible cases), which test level fits a change, that mocks belong only at
real process boundaries, that expensive setup happens once per run and not per test,
and that tests use no real sleeps. It SHALL name no test framework as a requirement
and SHALL stay short enough to read in one sitting.

#### Scenario: Update refreshes the policy

- **WHEN** `update` runs in a repository installed before this change
- **THEN** `docs/nogging/testing-policy.md` is present with the package's content

#### Scenario: The policy stays framework-neutral

- **WHEN** the shipped policy is read
- **THEN** every rule applies without any particular test framework, and a framework
  appears at most as an example

### Requirement: Agents receive the policy and the stages, not the full suite

`templates/agents-block.md`, `templates/claude-block.md`, `AGENTS.md`, `CLAUDE.md`,
the launch prompts and the specialist definitions SHALL reference the test policy and
SHALL direct execution agents to `nogg test changed`, `commit` and `bead` in place of
running `scripts/test`. They SHALL state that `nogg test full` is reserved for
releases, the nightly run and explicit, recorded exceptions.

#### Scenario: A Lead reads its block

- **WHEN** a Lead reads the installed agent instructions
- **THEN** they name the three stages for working, before a commit and once per Bead
- **AND** they link the test policy
- **AND** no instruction tells a Lead to run `scripts/test` once per Bead

### Requirement: The code reviewer checks test value

The `code-reviewer` specialist definition SHALL carry a test-value checklist: duplicated
tests, tests that mirror the implementation, tests at the wrong level, assertions on
source text, per-case API and database setup for input validation, and `_v2` files beside
originals. Findings SHALL use the existing severity scale.

#### Scenario: A mirror test is reviewed

- **WHEN** a reviewed diff adds a test that restates the implementation's own logic
- **THEN** the reviewer reports it as a test-value finding with a severity and a file
  and line

### Requirement: A task names its tests and their size

A `tasks.md` task SHALL carry a `Tests:` field in its block that names the scenarios to
test and gives each a size of `small`, `medium` or `large`, or says `none` with a reason.
`nogg validate` SHALL print a NOTE, and SHALL NOT fail, for an open task whose field is
missing or names no size. The planning prompts of every runtime SHALL require the field
and SHALL define the three sizes.

#### Scenario: A task without the field

- **WHEN** an open task has no `Tests:` field
- **THEN** `nogg validate` prints a NOTE naming the change and exits as before

#### Scenario: A documentation task

- **WHEN** a task says `Tests: none (documentation only).`
- **THEN** `nogg validate` prints no NOTE about it

### Requirement: A new task may not demand the full suite

`nogg validate` and `materialize` SHALL refuse an open task that has no Bead yet when the
text of its `Check:` field demands the full suite, by naming bare `scripts/test`, a
full, whole or entire suite, or `nogg test full`. The message SHALL name the task and
quote the match. `scripts/test --only`, `scripts/test-changed` and named test files SHALL
NOT match. An open task that already has a Bead SHALL produce a NOTE instead. This check
SHALL NOT run inside `mapping_audit`, so `doctor`, `recover` and `sync` never fail on it.
`materialize` SHALL refuse before it creates any Bead.

#### Scenario: A new task demands the full suite

- **WHEN** an unmapped open task says `Check: scripts/test`
- **THEN** `nogg validate` fails and names that task
- **AND** `materialize` creates no Bead for the change

#### Scenario: A named suite passes

- **WHEN** an unmapped open task says `Check: scripts/session-dispatch.test.sh`
- **THEN** neither `nogg validate` nor `materialize` refuses it

#### Scenario: An approved task is left alone

- **WHEN** a mapped open task says `Check: scripts/test`
- **THEN** `nogg validate` prints a NOTE and does not fail
- **AND** `doctor` does not fail and `sync` proceeds

### Requirement: Task sizing carries a per-Bead test budget

`task_sizing` SHALL accept `bead_test_lines` as a `[min, max]` pair of positive integers,
defaulting to `[1, 1500]`, printed by `nogg task-sizing`. It counts added plus deleted
lines in test files. A malformed value SHALL be a WARN that keeps the default. Like the
other sizing keys it SHALL be advisory and SHALL never fail a command.

#### Scenario: The budget prints

- **WHEN** `nogg task-sizing` runs with no configuration
- **THEN** it prints `bead_test_lines: 1-1500 (default)` with the two existing ranges

### Requirement: One integrity rule flags weakened tests

`scripts/check-test-integrity <base>` SHALL inspect the range from `<base>` to `HEAD` and
flag a deleted test, a newly added skip or expected-failure marker, and a modified test
file whose assertion count falls. A test that is moved or renamed within the range SHALL
NOT be flagged. A flag SHALL be cleared by a `Test-Integrity: <reason>` trailer on a commit
in the range. Without `--enforce` it SHALL print its findings and exit 0; with `--enforce`
it SHALL exit non-zero when an uncleared finding remains. Where the tracker is reachable,
`nogg test integrity` SHALL also require the Bead named by the trailer commit's `[<id>]`
token to carry the `discovery` label.

#### Scenario: A test is deleted without justification

- **WHEN** a range removes a test name that appears nowhere else in the range
- **THEN** the script names the file and the test
- **AND** with `--enforce` it exits non-zero

#### Scenario: A rename is not a deletion

- **WHEN** a test moves to another file within the range
- **THEN** the script flags nothing

#### Scenario: A justified removal passes

- **WHEN** a commit in the range carries `Test-Integrity: the behaviour was removed`
- **THEN** `--enforce` exits 0 and the finding prints as justified

#### Scenario: A trailer without a discovery note

- **WHEN** `bd` is reachable and the commit's Bead has no `discovery` label
- **THEN** `nogg test integrity` still reports the finding

#### Scenario: This repository's CI enforces it

- **WHEN** a pull request is opened against this repository
- **THEN** the `invariants` job runs the script with `--enforce` against the base ref
