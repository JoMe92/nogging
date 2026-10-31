## ADDED Requirements

### Requirement: One entry point runs each test stage

`nogg test changed|commit|bead|full` SHALL run the stage's commands from
`testing.stages`, as argv without a shell, in the checkout it was called from, through
`run-quiet` and under the session's `run-quiet` deny rules. A stage SHALL accept one
command string or a list run in order that stops at the first failure. A command SHALL
expand `{files}` and `{test_files}` into one `./`-prefixed argument per path, and
`{junit}` and `{timings}` into fresh result paths. A stage that ran nothing SHALL print
`skipped: <stage> ran no tests (<reason>)`, exit 0 and be recorded as skipped. The exit
code SHALL be the command's own on failure.

#### Scenario: A configured stage runs quietly

- **WHEN** `testing.stages.changed` is `pytest {test_files}` and one test file changed
- **THEN** pytest receives exactly that one path
- **AND** a passing run prints one summary line

#### Scenario: A command that needs files has none

- **WHEN** a stage command uses `{test_files}` and no test file changed
- **THEN** the command does not run and the stage prints the `skipped:` line

#### Scenario: A file name cannot become an option

- **WHEN** a changed file is named `-rf.test.sh`
- **THEN** the runner receives `./-rf.test.sh`

#### Scenario: A denied command stays denied

- **WHEN** a stage command matches the session's deny rules
- **THEN** it does not run and the refusal is reported as `run-quiet` reports it

### Requirement: Stages fall back to repository conventions

With no `testing.stages.<stage>`, `changed` and `commit` SHALL use `scripts/test-changed
{files}` when that file is executable and otherwise `scripts/test --only {test_files}`.
`bead` SHALL use the same commands over the diff from the merge-base with
`origin/<testing.ci.branch>` or `--base <ref>`, and SHALL use `scripts/test` when no CI is
configured. `full` SHALL use `scripts/test --timings {timings}`. `scripts/test` SHALL keep
its behaviour without arguments and SHALL keep skipping manifest-recorded self-tests.

#### Scenario: A repository with no testing block and no CI

- **WHEN** `nogg test bead` runs with no `testing` block, no CI and no `scripts/test-changed`
- **THEN** it runs `scripts/test`

#### Scenario: A repository with a test-changed script

- **WHEN** `scripts/test-changed` is executable and `nogg test changed` runs
- **THEN** that script receives the changed paths

#### Scenario: Self-tests stay excluded

- **WHEN** `scripts/test --only <shipped self-test>` runs in an installed consumer
- **THEN** that test does not run

### Requirement: Every stage has a reported time budget

`testing.budgets` SHALL default to `changed` 300, `commit` 600, `bead` 1800 and `full` 7200
seconds. A run above its budget SHALL print the stage, the elapsed and budgeted seconds, the
config key and its five slowest tests, and SHALL keep its own exit code. Time spent waiting
for a heavy slot SHALL NOT count against the budget.

#### Scenario: A green run over budget

- **WHEN** a `changed` run passes after 400 seconds with the default budget
- **THEN** it exits 0 and prints `over budget: changed took 400 s, budget 300 s
  (testing.budgets.changed)`

### Requirement: The full stage is refused unless a trigger permits it

`nogg test full` SHALL run only with `--release`, `--nightly`, `--allow-full "<reason>"` or
while the lock is inactive, and SHALL otherwise exit 77 naming the alternatives and be
recorded as refused. `testing.full_lock` SHALL accept `auto`, `always` and `never`. Under
`auto` the lock SHALL be active when a CI configuration file exists or the last nightly
record is at most 3 days old. `--release` SHALL be refused in a Lead or specialist session.
`--nightly` SHALL be refused in any supervised session. `--allow-full` SHALL require a
non-empty reason, and the reason SHALL be recorded.

#### Scenario: A Lead tries the full suite where CI is configured

- **WHEN** a Lead runs `nogg test full` in a repository with a workflow file
- **THEN** it exits 77 and names `nogg test bead`

#### Scenario: A repository with no CI

- **WHEN** `nogg test full` runs with no CI configuration and no nightly record
- **THEN** it runs

#### Scenario: An explicit exception

- **WHEN** a Lead runs `nogg test full --allow-full "migration touches every test"`
- **THEN** it runs and the record holds that reason

#### Scenario: A Lead claims a release

- **WHEN** a Lead session passes `--release`
- **THEN** the run is refused

### Requirement: Heavy runs share a host-wide slot limit

Stages in `testing.heavy_stages` (default `bead` and `full`) SHALL hold one of
`testing.max_parallel_heavy` (default 2) `flock` slots under `/tmp/nogg-test-slots-<uid>/`
for the whole run, across every repository and worktree of that user. A run with no free
slot SHALL print one waiting line and wait up to `testing.slot_wait_seconds`, then exit 75
naming the holders' stages. A slot SHALL be released by the holder's exit, however it exits.
When the slot directory cannot be used, the run SHALL proceed without a slot and say so.

#### Scenario: Three heavy runs on two slots

- **WHEN** a third heavy run starts while two hold slots
- **THEN** it prints one waiting line and starts when a slot frees

#### Scenario: A crashed holder

- **WHEN** a heavy run is killed with SIGKILL
- **THEN** the next run takes its slot without any cleanup step

#### Scenario: The slot directory is unusable

- **WHEN** the slot directory cannot be created
- **THEN** the stage still runs and prints that it ran without a slot

### Requirement: Every run leaves one record and surfaces its slowest tests

Each `nogg test` run SHALL append one schema-1 JSON line to
`.nogging/state/testing/runs.jsonl` in the main checkout, holding the stage, trigger,
status, exit code, seconds, wait seconds, budget, Bead, session, branch, head, test counts
and up to ten slowest tests, and SHALL NOT hold the command line. The file SHALL rotate
above 5 MiB. `nogg test` SHALL read test detail from JUnit XML at `{junit}` or from
`<seconds>\t<name>` lines at `{timings}`, and `bead` and `full` runs SHALL print their five
slowest tests. An unreadable result file or a failed record write SHALL NOT change the
test result.

#### Scenario: JUnit detail

- **WHEN** a stage writes valid JUnit XML to `{junit}`
- **THEN** the record holds the test counts and the ten slowest tests

#### Scenario: A broken result file

- **WHEN** the result file is malformed or above 32 MiB
- **THEN** the run keeps its exit code and the record has no test detail

#### Scenario: A linked worktree

- **WHEN** `nogg test` runs in a linked worktree
- **THEN** the record lands in the main checkout's state directory

### Requirement: A malformed testing block never fails a command

Every `testing` key SHALL be optional. A malformed value SHALL be a `doctor` WARN naming the
key and SHALL keep that key's default. An unknown key SHALL be a WARN. `update` SHALL NOT
edit a target's `.nogging/config.json`.

#### Scenario: A bad budget

- **WHEN** `testing.budgets.bead` is a string
- **THEN** `doctor` prints a WARN, exits as before, and `bead` uses 1800 seconds

### Requirement: doctor verifies that CI really runs tests

`doctor` SHALL report, from a result cached for at most `testing.ci.cache_seconds`, whether a
job matching `testing.ci.job_pattern` ran on `testing.ci.branch` or a pull-request run within
`testing.ci.max_age_days`. It SHALL print nothing when tests ran, a NOTE with the age when
the last test job is older than that window, a WARN naming the branch, the pattern and the
nightly fallback when CI is configured and no test job is found, and a NOTE naming the nightly
fallback when no CI is configured and no nightly record exists. With no `gh`, no
authentication, no network, no GitHub remote or a timeout, it SHALL print nothing new, and a
refresh SHALL take at most 10 seconds. The check SHALL NOT change `doctor`'s exit code.

#### Scenario: A workflow that never runs tests

- **WHEN** a workflow file exists and no test job ran on the integration branch in the window
- **THEN** `doctor` prints a WARN naming the branch and the nightly fallback

#### Scenario: A repository with no CI

- **WHEN** no CI configuration file and no nightly record exist
- **THEN** `doctor` prints a NOTE naming the nightly fallback and no WARN

#### Scenario: Offline

- **WHEN** CI is configured and `gh` cannot reach GitHub
- **THEN** `doctor` prints no CI line and exits as before

#### Scenario: A cached result

- **WHEN** a result younger than `cache_seconds` exists
- **THEN** `doctor` calls no `gh` command

#### Scenario: A red test job

- **WHEN** a test job ran and failed
- **THEN** it counts as having run

### Requirement: A nightly run covers repositories whose CI runs no tests

`nogg test nightly` SHALL exit 0 without running tests when `testing.nightly.enabled` is
false, when called in a supervised session, when the cached CI result shows tests ran, or
when the commit of `origin/<testing.ci.branch>` was already tested. It SHALL defer while the
1-minute load exceeds half the core count or a heavy slot is held, except at the last firing
of the night. It SHALL run `testing.nightly.setup` and then the full stage in a retained
detached worktree beside the main checkout, never in the shared checkout or a Lead's
worktree, and SHALL write `.nogging/state/testing/nightly-last.json`. `doctor` SHALL print a
WARN for a failed last run, and a NOTE to enable the timer when the CI result is `none` or no
CI is configured, and no nightly record exists.

#### Scenario: CI runs the tests

- **WHEN** the timer fires and the cached CI result shows tests ran
- **THEN** no test runs and the skip is recorded

#### Scenario: The commit is already tested

- **WHEN** the last nightly record holds the current commit
- **THEN** no test runs

#### Scenario: A busy host

- **WHEN** the timer fires at 02:17 with the load above half the core count
- **THEN** the run defers
- **AND** the 05:17 firing runs regardless of load

#### Scenario: Offline

- **WHEN** the fetch fails
- **THEN** the run uses the last known `origin/<branch>` and the record says so

#### Scenario: The shared checkout is untouched

- **WHEN** a nightly run finishes
- **THEN** the main checkout's branch, index and working tree are unchanged

### Requirement: A failed nightly run reaches the orchestrator once

Each dispatch pass SHALL read the nightly record and hold one non-urgent digest item of kind
`nightly_failed`, keyed by run ID, while the last record failed, and SHALL clear it when a later
record passes. The item SHALL pass the digest's field rules, so its text is bounded and quoted
as data. With no orchestrator session it SHALL be held like any other item. Repeated passes
SHALL NOT produce a second item.

#### Scenario: A failure

- **WHEN** a nightly run fails and dispatch is on
- **THEN** the next digest names the failed commit and the log path

#### Scenario: A later pass

- **WHEN** a later nightly run passes
- **THEN** the item clears

### Requirement: Test metrics are reported per Bead and as a daily trend

`nogg test report [--days N] [--json]` SHALL print, per day and stage, the runs, failures,
median seconds and over-budget count, plus the slowest tests of the window, the explicit full
runs and the week-over-week change. `token-usage report --group-by bead` SHALL add stage
seconds, tests added, tests deleted and skips added per Bead, and SHALL keep its existing JSON
fields. `nogg test bead` and `nogg test report` SHALL name a Bead outside
`task_sizing.bead_test_lines`. `doctor` SHALL print a NOTE when a stage's 7-day median exceeds
the previous 7 days by `testing.trend_threshold_percent` with at least three runs in each
window, when the latest run of a stage was over budget, or when a Lead session used
`--allow-full` in the last 7 days. None of these SHALL change `doctor`'s exit code.

#### Scenario: A suite that grows

- **WHEN** the `bead` median rises from 300 to 500 seconds week over week with enough runs
- **THEN** `doctor` prints a NOTE naming the stage and the change

#### Scenario: Too few runs

- **WHEN** a window has two runs
- **THEN** `doctor` prints no trend NOTE

#### Scenario: A Bead above its test budget

- **WHEN** a Bead's test lines exceed the maximum
- **THEN** `nogg test bead` names the count and the budget and keeps its exit code

#### Scenario: No records yet

- **WHEN** `nogg test report` runs with no record
- **THEN** it says so and exits 0

### Requirement: The bead stage runs the integrity check

`nogg test bead` SHALL run the integrity rule over its change set after its commands, and
`nogg test integrity [--base <ref>]` SHALL run it alone. With `testing.integrity` at `report`,
the default, findings SHALL print without changing the exit code. At `enforce`, an uncleared
finding SHALL make the stage fail. This repository SHALL set `enforce`.

#### Scenario: The default in a consumer

- **WHEN** a consumer with no `testing` block deletes a test and runs `nogg test bead`
- **THEN** the finding prints and the exit code is the stage's own
