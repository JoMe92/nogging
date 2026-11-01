## Context

The Product Owner approved the brief on 2026-10-31: Nogging ships a test policy
and the mechanics that enforce it, so that a consumer repository cannot drift to
a 45-minute agent-written suite that blocks development. Phases 1 and 2 are
planned here; phase 3 is a recorded follow-up. The proposal holds the evidence.

What the code offers today, read for this design:

- `run-quiet` already gives one blocking call, one summary line, a failure tail
  and the session's deny rules (`scripts/nogg`, `run_quiet`). Nothing wraps it.
- `scripts/test` runs every `scripts/**/*.test.sh` serially and takes no argument.
  Consumer self-test exclusion comes from `.nogging/installed-manifest.json`.
- `.github/workflows/nogging-validate.yml` is **not shipped to consumers**, and CI
  has no `bd`. A consumer has no CI rule from Nogging; a rule that needs the
  tracker cannot run in CI.
- `core.hooksPath` points at `.beads/hooks`, so Nogging's Git hooks often do not
  run. The CI `invariants` job is the backstop for this repository only.
- `validate()` feeds `doctor`, `recover` and `sync` through `mapping_audit`. A new
  FAIL added there would redden `doctor` and stall sync for an old plan.
- `TASK_SIZING_DEFAULTS` is advisory: `validate` only prints NOTEs.
- Session dispatch is a level-triggered pass that derives its queue from live
  evidence, and `session_wake.py` shapes the digest. It only needs a new fact.
- `token_usage_report.bead_git_lines` already splits production and test lines by
  `TEST_PATH_RE`, and `TEST_PATH_RE` matches `(^|/)test_[^/]*\.py$`.
- `renderSystemd` renders every unit in `manifest.systemd`, and `nextsteps.js`
  names what to enable. Installers render; operators enable.
- LoadCompass's `scripts/test-changed` caps runs with `flock` slots under
  `${TMPDIR:-/tmp}`. A per-session `TMPDIR` would silently split that cap.
- A Lead pushes over HTTPS with a token that has no `workflow` scope, so a push
  that changes `.github/workflows/` is refused. SPEC-mmio hit this on 2026-10-26
  and the orchestrator pushed that commit over SSH.

Discoveries folded in: SPEC-la92 (a 5,754 s full suite and a nested 180 s bound
that overran under load), SPEC-abb2 and SPEC-hoyh (the same nested bound), and
SPEC-93hk and SPEC-9txl (suites inherit a session's `NOGG_*`; `test-env.sh` now
clears them, so `scripts/test` reads any option before sourcing it).

## Goals / Non-Goals

**Goals:**

- One command per testing moment, whose defaults keep an existing repository
  working and whose configuration lets a repository express its own runners.
- A full suite that is refused by default where something else runs it.
- A cost that is visible: budgets, slowest tests, a daily trend, per-Bead figures.
- Evidence that CI really tests, and a fallback when it does not.
- Plans and reviews that stop adding low-value tests.
- Beads that can run in parallel.

**Non-Goals:**

- Blocking direct runner calls (`scripts/test`, `pytest`). See Decision 15.
- Killing a run that exceeds its budget. Budgets report.
- A test-selection engine. A repository brings its own (`vitest related`,
  `pytest --testmon`, `nx affected`); Nogging passes it the changed files.
- Framework-specific behaviour in the policy or in `nogg test`.
- Coverage targets, mutation testing, or deletion of tests (phase 3).
- Configuring LoadCompass. Adopting the stages there is that repository's work.

## Decisions

### Decision 1: New logic lives in `scripts/lib/testing_*.py`, not in `scripts/nogg`

`scripts/nogg` gains only argument wiring and thin effectful wrappers. Pure logic
goes to `testing_stages.py`, `testing_runs.py`, `testing_diff.py`, `testing_ci.py`,
`testing_nightly.py` and `testing_report.py`, with facts and clock passed in, as
`session_dispatch.py` does. That keeps Leads out of each other's way in an
11,900-line file and keeps most tests small.

The prefix is `testing_`, deliberately not `test_`: `TEST_PATH_RE` would classify
`scripts/lib/test_stages.py` as a test, so its lines would vanish from the
production count, and the integrity check would read it as a test file.

Each module is listed in `bin/lib/manifest.js` (`verbatim`) and `package.json`
(`files`). New `*.test.sh` files are **not** added to `verbatim`, so they are never
shipped and the v3.3.0 self-test exclusion stays exactly as it is.

### Decision 2: The `testing` block and its defaults

Every key is optional; an absent or malformed key keeps its default. A malformed
value is a `doctor` WARN, never a FAIL, like `task_sizing`.

```json
"testing": {
  "stages": {},
  "budgets": {"changed": 300, "commit": 600, "bead": 1800, "full": 7200},
  "max_parallel_heavy": 2,
  "heavy_stages": ["bead", "full"],
  "slot_wait_seconds": 3600,
  "full_lock": "auto",
  "integrity": "report",
  "trend_threshold_percent": 30,
  "ci": {"branch": "develop", "job_pattern": "test", "max_age_days": 7,
         "cache_seconds": 21600},
  "nightly": {"enabled": true, "setup": []}
}
```

TASK-TPC-002 parses and validates the whole block, including the keys later Beads
consume, so no later Bead has to touch the parser. Budgets are generous on purpose:
the 7,200 s `full` budget fits this repository's measured 5,754 s on a Raspberry Pi.

### Decision 3: Stage resolution and change sets

A stage value is a command string or a list of command strings run in order,
stopping at the first failure, so `commit` can hold tests plus lint.

| Stage | Change set | Default with no `testing.stages.<stage>` |
| --- | --- | --- |
| `changed` | tracked changes and untracked files against `HEAD` | `scripts/test-changed {files}` if executable, else `scripts/test --only {test_files}` |
| `commit` | same as `changed` | same as `changed` |
| `bead` | those plus the diff from the merge-base with `origin/<ci.branch>`; `--base <ref>` overrides | same as `changed`; `scripts/test` when no CI is configured |
| `full` | none | `scripts/test --timings {timings}` |

The `bead` fallback keeps today's written rule: "`scripts/test` once per Bead only
where the project has no CI". Deleted paths are left out of a change set, because
no runner can open them. When a command needs `{files}` or `{test_files}` and the
set is empty, it is skipped. A stage that ran nothing prints `skipped: <stage> ran
no tests (<reason>)`, exits 0 and is recorded `skipped`, so a green line never hides
an empty run.

`TEST_PATH_RE` decides what `{test_files}` holds. `scripts/test --only <paths>`
runs a `*.test.sh` with bash and a `*_test.py` with python3, and reports any other
path as not runnable. `scripts/test` reads `--only` and `--timings` before it
sources `test-env.sh`. With no argument it behaves exactly as before, and
self-test exclusion still applies to what `--only` selects from the manifest.

### Decision 4: Commands are argv, with four placeholders

A command string goes through `shlex.split`, never a shell, and the deny rules of
`run-quiet` apply, because the string comes from a file a Lead can edit. A
pipeline belongs in a script. Placeholders:

- `{files}`, `{test_files}`: expand as a whole word into one argument per path.
  Each path is written `./<path>` so a file name cannot become an option.
- `{junit}`: a fresh path the runner writes JUnit XML to.
- `{timings}`: a fresh path the runner writes `<seconds>\t<name>` lines to.

Output goes through `run_quiet` itself, with the log under
`.nogging/state/testing/logs/`, the newest 20 kept. `nogg test` adds lines after
its summary line and never replaces it.

### Decision 5: Budgets report and never kill

An over-budget run keeps its own exit code and prints
`over budget: <stage> took <n> s, budget <m> s (testing.budgets.<stage>)` plus its
five slowest tests. Killing a run wastes the run; a suite that is too slow needs a
decision, not an interruption. `doctor` and `nogg test report` repeat it. Time
spent waiting for a slot does not count against the budget.

### Decision 6: The full-suite lock

`nogg test full` runs when any of these holds, and otherwise refuses with exit 77
and the exact alternatives:

| Trigger | Allowed from |
| --- | --- |
| `--release` | an operator shell or the Orchestration Agent; refused in a Lead or specialist session |
| `--nightly` | outside any supervised session; used by `nogg test nightly` |
| `--allow-full "<reason>"` | anywhere; the reason is mandatory and recorded |
| lock inactive | anywhere |

`testing.full_lock`: `auto` locks when CI is configured or when the nightly run is
in use; `always` locks; `never` does not. CI counts as configured when
`.github/workflows/*.y*ml`, `.gitlab-ci.yml`, `.circleci/config.yml` or a
`Jenkinsfile` exists. This is a static check on purpose: it needs no network and
gives the right answer in LoadCompass, whose workflow exists but never runs tests,
because `doctor` reports that gap and the nightly run covers it. The nightly run
counts as in use when its last record is at most 3 days old (TASK-TPC-005). A
repository with neither is unlocked, so an `update` changes nothing for it.

Every explicit run is recorded with its trigger and reason. `doctor` names
`--allow-full` runs from Lead sessions, because an agent can pass the flag: the
safeguard is visibility, as for the orchestrator's floor.

### Decision 7: Heavy slots are one host-wide `flock` set under a fixed path

Stages in `heavy_stages` take one of `max_parallel_heavy` slots:
`/tmp/nogg-test-slots-<uid>/slot.<n>`, a directory of mode 0700. The path is fixed
rather than `$TMPDIR`, because a per-session `TMPDIR` would split the cap, which is
the weakness in LoadCompass's script, and it is not under `$HOME`, which a
sandboxed session cannot write. `flock` binds to the inode, so a slot works across
repositories, worktrees and the mount and PID namespaces of a fenced session; the
kernel frees it when the holder dies, so nothing goes stale; and the descriptor is
close-on-exec, so a stray daemon cannot keep it.

`nogg test` polls every 5 seconds and prints one line when it starts to wait. After
`slot_wait_seconds` it exits 75 with the holders' stages. If the slot directory
cannot be used, the run proceeds without a slot and says so: a limit that can stop
tests from running is worse than one that sometimes does not apply. Different
repositories may configure different limits; each counts the same files against its
own limit, which is good enough for a shared host.

### Decision 8: One append-only run record, in the main checkout

Each run appends one JSON line to `.nogging/state/testing/runs.jsonl` in the main
checkout (resolved through `canonical_repository_state`), so all worktrees feed one
trend. Schema 1 holds `id`, `at`, `stage`, `trigger`, `reason`, `status` (`passed`,
`failed`, `skipped`, `refused`), `exit`, `seconds`, `wait_seconds`,
`budget_seconds`, `over_budget`, `bead`, `session`, `role`, `branch`, `head`,
`tests`, `failed_tests`, `skipped_tests`, and `slowest` (at most ten of `{name,
seconds}`). It never holds the command line, because a command may hold a secret.
Over 5 MiB it rotates to `runs.jsonl.1`; readers use both. A failed write is one
stderr line and never changes the test result.

The Bead comes from `--bead`, then the session record, then the newest `[<id>]`
commit subject on the branch, else null. A restricted Lead can write this file, so
it is no trust boundary: readers validate every field, and a field that reaches the
digest passes the digest's existing field rules.

Test detail comes from `{junit}` when used, else `{timings}`. JUnit parsing uses
the standard library, refuses a file above 32 MiB and treats a parse failure as "no
detail", never as a failed run. `scripts/test --timings` gives per-file seconds, so
this repository and shell-based consumers get the same report.

### Decision 9: New tasks are checked strictly, old tasks are only noted

`Check:` text that demands the full suite is the defect. It matches, in an open
task's joined block, the text after `Check:` up to the next field:

```text
\bscripts/test\b(?![-./\w]|\s+--only)   \b(full|whole|entire)\s+(test\s+)?suite\b   \bnogg\s+test\s+full\b
```

An **unmapped** open task (no Bead yet) with such a `Check:` is refused by
`nogg validate` and by `materialize`, before the first `bd create`. A **mapped** open
task gets a NOTE: open `TASK-DRO-007` says `scripts/test`, and a consumer has the
same, and a new failure on approved work would redden an `update`. The check lives
outside `mapping_audit`, so `doctor`, `recover` and `sync` never see it as a FAIL.

`Tests:` names scenarios and sizes, in the same block:

```text
Tests: small Scenario "Full is refused"; medium 'nogg test bead' on a temporary repository.
Tests: none (documentation only).
```

- **small**: in-process, no subprocess, under 1 second each.
- **medium**: local processes and temporary repositories, stubs only at process
  boundaries, seconds each.
- **large**: packed installs or real multi-process flows, only where a scenario
  cannot be shown smaller.

A missing `Tests:` field, or one naming no size, is a NOTE like a missing `[~N loc]`
estimate, never a failure. Hundreds of existing fixtures and every old plan carry no
such field, and the brief asks to reject full-suite `Check:` fields, not to fail old
format. The planning prompts for every runtime require the field.

`task_sizing.bead_test_lines`, default `[1, 1500]`, is the third `[min, max]` key
and prints through `task-sizing`. Test lines are added plus deleted lines by
`classify_path`. It is advisory, like its siblings, and reported per Bead
(Decision 13). The minimum is what makes a Bead with production code and no test
line visible.

### Decision 10: Integrity is one rule script, justified by a commit trailer

`scripts/check-test-integrity <base>` works like `scripts/check-branch-name`: one
implementation, called by the CI `invariants` job and by `nogg test`. It diffs the
whole range `<base>...HEAD` and uses `testing_diff.py` to flag, in test files as
`TEST_PATH_RE` sees them:

- a deleted test: a deleted test file, or a test name removed and not added
  anywhere else in the range, so a move or rename passes;
- a new skip: an added line matching the table of `skip`/`xfail` forms for pytest,
  unittest, Jest/Vitest, Go, Rust and JUnit;
- removed assertions: a modified test file whose assertion count falls.

Evaluating the range, not each commit, means a test added and removed inside one
branch is no finding. A shell test has no named cases, so it is flagged only when
the file is deleted or its `check`/`assert` count falls.

The brief says "without a discovery note", and CI has no `bd`. The justification
must travel in history, as `Nogging-Writer:` does: a `Test-Integrity: <reason>`
trailer on any commit in the range satisfies the rule. Where the tracker is
reachable, `nogg test integrity` also requires the Bead named by that commit's
`[<id>]` token to carry the `discovery` label, so the note still exists. The
Lead's written rule is both: the trailer and the discovery note.

`testing.integrity` is `report` by default (findings print, the exit code does not
change) and `enforce` here. The CI step passes `--enforce`. Consumers get the check
through `nogg test bead`, because they have no workflow from us;
`docs/test-control.md` shows the one CI line to add.

### Decision 11: The CI reality check reads `gh`, caches, and stays quiet offline

`doctor` calls `testing_ci.py` with a cached result from
`.nogging/state/testing/ci-check.json`, at most `cache_seconds` old. A refresh runs
`gh run list --limit 30` and `gh run view --json jobs` on at most three candidate
runs, within 10 seconds in total. A candidate is a run on `ci.branch`, or a
`pull_request` run, newer than `max_age_days`. A test job is a job whose name
matches `job_pattern` (case-insensitive) and whose conclusion is neither `skipped`
nor `cancelled`; a red job still proves tests ran.

| Result | `doctor` |
| --- | --- |
| `ran` | nothing |
| `unknown` (no `gh`, not authenticated, offline, no GitHub remote, timeout) | nothing; a stale cached result keeps its own line with its age |
| `stale` (last test job older than `max_age_days`) | NOTE with the age |
| `none` (CI configured, no test job found) | WARN naming the branch and pattern, with the nightly fallback as the fix |
| `absent` (no CI configured) | NOTE naming the nightly fallback, unless a nightly record exists |

`absent` is a NOTE and not a WARN because a repository with no CI is not misconfigured,
and it needs no network, so it prints offline too. Nothing here changes `doctor`'s exit code. A `pull_request` run does not expose its
base branch through `gh run list`, so a PR run against another branch counts too.
That is accepted: this catches the failure that matters, a repository where test
jobs do not run at all.

### Decision 12: The nightly units are always rendered and decide at run time

The brief says to render the timer "when no CI runs tests". The installer is
offline Node and cannot know that; a static check would get LoadCompass wrong, since
its workflow exists and runs no test. So `init` and `update` always render
`nogg-nightly-<slug>.{service,timer}`, and `nogg test nightly` decides each night.
Rendering is harmless, enabling stays the operator's act, and `doctor` says when to
enable it: a CI result of `none` or `absent` with no nightly record.

The timer fires hourly at `*-*-* 01..05:17:00`. Each firing runs, in order:

1. Exit quietly when `nightly.enabled` is false or a session calls it.
2. Skip when the CI result, refreshed if older than `cache_seconds`, is `ran`.
   `unknown` runs, since the operator enabled the timer.
3. Fetch `ci.branch` (offline: use the last known `origin/<branch>`, and record
   that). Skip when that commit was already tested.
4. Defer when the host is busy: 1-minute load above half the core count, or a heavy
   slot held. The 05:17 firing runs anyway, so a busy host still gets a run.
5. Update the retained detached worktree at `<main>-nightly`, a sibling like every
   other Nogging worktree, with `reset --hard` and `clean -fd`. Ignored files
   survive, so `node_modules` stays. It is not a recorded worktree and nothing in
   `doctor` reads it. A shared checkout is never used: sync commits there, and a
   Lead may be working.
6. Run `nightly.setup`, then `nogg test full --nightly` in that worktree. The
   service sets `Nice=15` and `IOSchedulingClass=idle`.
7. Write `.nogging/state/testing/nightly-last.json`: `run_id`, `at`, `status`,
   `head`, `seconds`, `log`, and up to five failed test names.

Dispatch reads that record each pass, level-triggered: a `failed` record is one
digest item of kind `nightly_failed`, keyed by `run_id`, that clears when a later
record passes. It is not urgent, so it does not break quiet hours or wake rules.
With no orchestrator it is held like any item. `doctor` prints a WARN for a failed
last run regardless, so the failure is visible with dispatch off.

### Decision 13: Metrics reuse the run records and one diff analysis

`testing_report.py` aggregates pure data. `nogg test report [--days N] [--json]`
prints a daily row per stage (runs, failures, median seconds, over-budget count), the
slowest tests of the window, explicit full runs, and the week-over-week change.

`token-usage report --group-by bead` gains test columns: stage seconds from the run
records, and tests added, tests deleted and skips added from `testing_diff.py` on
each Bead's commits. The report's existing JSON `test_lines` stays. A Bead above or
below `bead_test_lines` is listed by `nogg test report` and printed by `nogg test
bead`.

`doctor` adds a NOTE when a stage's median over the last 7 days exceeds the previous
7 days by `trend_threshold_percent`, with at least three runs in each window, or when
its latest run was over budget. LoadCompass grew 450 % in 4 days, so a weekly check
at 30 % catches that early.

### Decision 14: Safe defaults for an existing consumer

An `update` of a repository with no `testing` block changes this and nothing else:

| Surface | Behaviour with no `testing` block |
| --- | --- |
| `scripts/test` | unchanged without arguments; self-tests stay excluded |
| `nogg test changed` and `commit` | `scripts/test-changed` if present; else changed `*.test.sh`; else `skipped` |
| `nogg test bead` | as above; `scripts/test` when no CI is configured, as today's rule says |
| `nogg test full` | runs when no CI is configured; refused with a named alternative when CI is configured |
| budgets | report only, generous |
| slots | at most 2 heavy `nogg test` runs per host; a direct `scripts/test` takes none |
| `validate` / `doctor` | mapped tasks only gain NOTEs; `doctor` gains at most WARNs and NOTEs, never a FAIL |
| integrity | prints findings, never fails |
| nightly | rendered, not enabled |

`update` never edits a target's `.nogging/config.json`. It prints one line, like the
`session_dispatch` notice, saying the defaults apply and where to set stages. New
installs scaffold the `testing` block from `templates/nogging-config.json`, with
`stages` empty.

### Decision 15: Direct runner calls are guided, not blocked

`nogg test` cannot stop `pytest`, and a PreToolUse rule would mean per-runtime
matchers for every framework in every consumer. `Bash(scripts/test:*)` in a deny list
would also block the repository's own `--only` use. So the mechanism is the guidance,
the budget, the CI check and the nightly run, and the metric shows only runs through
`nogg test`. This is the main residual risk: an agent that ignores its instructions
can still run a full suite directly. It is accepted for this release, because today's
instructions and plans still name `scripts/test`, so the first step is to stop telling
agents to run it, and the records will show whether that is enough. A later change can add a runtime rule if it is not.

### Decision 16: Phase 3 is a deferred follow-up Bead

`nogg test prune-candidates` needs per-test coverage, and coverage tooling is
framework-specific, so it does not fit this change cheaply. One Bead with
`openspec:followup` and `openspec:change:test-policy-and-test-control` records it,
deferred with no task mapping, and therefore blocks neither this change's completion
nor `bd ready`. Its input will be the records from Decision 8.

### Decision 17: Slicing, order and branches

Seven vertical slices. Dependencies are real data or text dependencies only:

| Task | Delivers | Blocked by | Branch type |
| --- | --- | --- | --- |
| TPC-001 | policy, reviewer checklist, task format, test budget key | none | `docs/` |
| TPC-002 | `nogg test` stages, budgets, lock, slots, records | none | `feat/` |
| TPC-003 | integrity rule script, CI step | none | `test/` |
| TPC-004 | agent guidance on the stages, CI reality check | 001, 002 | `chore/` |
| TPC-005 | nightly fallback and digest | 002, 004 | `feat/` |
| TPC-006 | metrics, trend, integrity in `bead` | 001, 002, 003 | `perf/` |
| TPC-007 | packed end-to-end consumer proof | 001 to 006 | `test/` |

TPC-001, 002 and 003 can run at once, then 004 and 006, then 005. Each branch type is
distinct while Beads overlap, since a change branch is `<type>/<change>` and two Leads
cannot share one. `feat/` returns for TPC-005 and `test/` for TPC-007 only after the
earlier Bead on that branch type has merged.

TPC-004 needs TPC-001 for the policy path and TPC-002 for the commands. TPC-005 needs
the CI result from TPC-004. TPC-006 reads `task_sizing.bead_test_lines`, the run
records and `testing_diff.py`.

The CI step of TPC-003 changes `.github/workflows/nogging-validate.yml`, and a Lead's
HTTPS push of that file is refused. That Lead keeps the step as its own last commit
and, when the push is refused, records a discovery and signals blocked. The
orchestrator then pushes it over SSH, the path SPEC-mmio used.

## Risks / Trade-offs

- **An agent passes `--allow-full`.** Recorded with its reason and shown by `doctor`.
- **An agent bypasses `nogg test`.** Accepted for this release (Decision 15).
- **`/tmp` is private in some sandbox.** The slot then splits or fails open. A
  slot limit is load management, not a safety boundary, and the run still happens.
- **`job_pattern` misses a repository's job name.** `doctor` gives a false WARN whose
  text names the pattern to change. A WARN never changes the exit code.
- **False positives in the integrity check.** A legitimate refactor can trip it. A
  trailer clears it, and it is report-only by default.
- **`Check:` pattern false positives.** "not the full suite" matches. Only unmapped
  tasks are refused and the message quotes the match, so the planner rewords it.
- **The nightly worktree ages.** It lives beside the repository until `git worktree
  remove`; `remove` lists it in its next steps.
- **A nightly run competes with overnight Leads.** It waits for a slot, runs at low
  priority, and runs at most once per commit.

## Migration Plan

1. Merge per Decision 17. Each Bead keeps `scripts/test` and CI green on its own.
2. Every Bead adds its entry under `## [Unreleased]` in `CHANGELOG.md`.
3. The orchestrator cuts v3.6.0 after TPC-007.
4. Consumers run `update`, then set `testing.stages`, and enable the nightly timer
   when `doctor` asks for it.

Rollback is `update` to the previous release. All new state sits under
`.nogging/state/testing/`, and an older `scripts/nogg` ignores the `testing` key.

## Open Questions

None. The defaults above stand unless the Product Owner changes them.
