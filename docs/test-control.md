# Test control

`nogg test` gives each testing moment one command. Stages run quietly under a time
budget, the full suite stays with CI, heavy runs share a host-wide limit, and every
run leaves a record. It works with no configuration, and it runs whatever test
runners a repository already has.

## The stages

| Stage | When | What it covers |
| --- | --- | --- |
| `nogg test changed` | while working | tracked changes and untracked files against `HEAD` |
| `nogg test commit` | before each commit | the same, usually with lint added |
| `nogg test bead` | once per Bead, before closing it | those plus the branch's diff from its merge-base |
| `nogg test full` | CI, a release, the nightly run | everything |

Run them from the root of a checkout. A stage prints the one summary line of
`run-quiet`, plus the log tail on failure, and exits with its command's code. The
logs of the newest 20 commands stay in `.nogging/state/testing/logs/`.

`bead` diffs from the merge-base with `origin/<testing.ci.branch>`, and `--base <ref>`
overrides that. Without such a merge-base the stage covers the uncommitted work and
says so. A deleted path is never part of a change set, because no runner can open it.

A stage that ran nothing never looks green:

```text
skipped: changed ran no tests (no changed test files)
```

It exits 0 and is recorded as `skipped`.

## Configuring your runners

With no configuration, `changed` and `commit` use `scripts/test-changed {files}` if
that file is executable, and otherwise `scripts/test --only {test_files}`. `bead`
does the same where CI is configured, and runs the whole `scripts/test` where it is
not. `full` runs `scripts/test --timings {timings}`. Set `testing.stages` for
anything else:

```json
"testing": {
  "stages": {
    "changed": "pytest -q {test_files}",
    "commit": ["pytest -q {test_files}", "ruff check {files}"],
    "bead": "pytest --testmon --junitxml={junit}",
    "full": "pytest --junitxml={junit}"
  }
}
```

A list runs in order and stops at the first failure. Commands run without a shell,
so a pipeline belongs in a script. They pass the same deny rules as `run-quiet`,
because the configuration is a file an agent can edit.

| Placeholder | Becomes |
| --- | --- |
| `{files}` | every path in the change set, one argument each |
| `{test_files}` | those of them that are tests |
| `{junit}` | a fresh path the runner writes JUnit XML to |
| `{timings}` | a fresh path the runner writes `<seconds><TAB><name>` lines to |

`{files}` and `{test_files}` must stand alone as a word, and each path is written
`./<path>`, so a file named `-rf.test.sh` cannot become an option. When either has
nothing to hold, that command is skipped. `scripts/test --only` receives only what
it can run: a `*.test.sh` with bash and a `*_test.py` with python3.

## Budgets

A run above `testing.budgets.<stage>` keeps its exit code and prints the budget line
and its five slowest tests:

```text
over budget: changed took 400 s, budget 300 s (testing.budgets.changed)
```

Budgets report and never kill: a killed run is wasted, and a suite that is too slow
needs a decision, not an interruption. Time spent waiting for a slot does not count.

## The full-suite lock

Under the default `testing.full_lock: auto`, `nogg test full` is locked where a CI
configuration file exists (`.github/workflows/*.yml`, `.gitlab-ci.yml`,
`.circleci/config.yml`, a `Jenkinsfile`), or where a nightly run wrote a record in
the last 3 days. A repository with neither stays unlocked. A locked run exits 77,
names the alternatives and is recorded as refused.

| Trigger | Allowed from |
| --- | --- |
| `--release` | an operator shell or the Orchestration Agent |
| `--nightly` | outside any supervised session |
| `--allow-full "<reason>"` | anywhere; the reason is recorded |

`--allow-full` is deliberately open to an agent. The safeguard is that every use
leaves its reason in the record.

## Heavy slots

Stages in `testing.heavy_stages` hold one of `testing.max_parallel_heavy` slots for
the whole run, across every repository and worktree of that user on the host. A run
with no free slot prints one line and waits for up to `testing.slot_wait_seconds`,
then exits 75 and names what holds the slots. A direct call of `scripts/test` takes
no slot.

The slots are `flock` files under `/tmp/nogg-test-slots-<uid>/`. The kernel frees one
when its holder exits, however it exits, so nothing goes stale and nothing needs
cleaning. If that directory cannot be used, the run goes ahead without a slot and
says so, because a limit that stops tests from running is worse than one that
sometimes does not apply.

## Integrity

The `bead` stage ends with the test-integrity rule over the branch's change set, and
`nogg test integrity [--base <ref>]` runs it alone. The rule is
`scripts/check-test-integrity`: it flags a deleted test or test file, a newly added
skip or expected failure and a modified test file whose assertion count falls, and a
moved or renamed test is no finding. A `Test-Integrity: <reason>` trailer on a commit
in the range justifies the findings. Where `bd` is reachable, the Bead named by that
commit's `[<id>]` token must also carry the `discovery` label, so the reason is
written down where a planning session reads it.

`testing.integrity` sets what a finding does. At `report`, the default, findings
print and the exit code stays the stage's own. At `enforce` an uncleared finding
makes `bead` or `integrity` exit 1; this repository sets `enforce`. A base that does
not resolve prints a line in `bead` and exits 2 in `integrity`. A consumer gets the
check through `nogg test bead`; to enforce it in CI too, add the one line shown in
[Operating model](operating-model.md).

`bead` also prints the Bead's test-line count against `task_sizing.bead_test_lines`.
A Bead above the maximum, or one that changes production code with no test line,
gets a `NOTE:` naming the count and the budget. It never changes the exit code.

## Reading the cost

`nogg test report [--days N] [--json]` prints, for the last `N` days (default 14), a
row per day and stage with the runs, failures, median seconds and over-budget runs,
then the week-over-week change of each stage's median, the slowest tests, the full
runs with their trigger and reason, and the Beads outside `bead_test_lines`. With no
record yet it says so and exits 0. `--json` prints the same as one document.
`token-usage report --group-by bead` adds the per-Bead columns described in
[Token usage](token-usage.md).

`doctor` turns the same records into NOTEs, never a WARN or a failure:

- a stage whose median over the last 7 days exceeds the 7 days before by
  `testing.trend_threshold_percent` (default 30), with at least three runs in each
  window;
- a stage whose latest run was over its budget;
- a Lead session's `--allow-full` in the last 7 days.

## Run records

Each run appends one JSON line to `.nogging/state/testing/runs.jsonl` in the main
checkout, so all worktrees feed one history. The file rotates to `runs.jsonl.1` above
5 MiB. A record holds the stage, trigger and reason, status, exit code, seconds, wait,
budget, Bead, session, role, branch, head, test counts and the ten slowest tests. It
never holds the command line, because a command may hold a secret.

Test detail comes from `{junit}` if the command uses it, else from `{timings}`. A
malformed result file, one above 32 MiB, or a record that cannot be written changes
nothing about the test result.

## Does CI really run tests?

`nogg doctor` checks, and a green `develop` that never ran a test is the failure it
looks for. It asks `gh` for the newest runs on `testing.ci.branch` and for
pull-request runs, and looks at up to three of them for a job whose name matches
`testing.ci.job_pattern`, ignoring case. A job that was skipped or cancelled does not
count; a job that failed does, because it proves the tests ran.

| Result | `doctor` prints |
| --- | --- |
| tests ran | nothing |
| the last test job is older than `testing.ci.max_age_days` | a NOTE with its age |
| CI is configured and no test job is found | a WARN naming the branch, the pattern and the nightly fallback |
| no CI configuration file exists | a NOTE naming the nightly fallback, unless a nightly run wrote a record |
| `gh` is missing, unauthenticated, offline, has no GitHub remote or times out | nothing; an older cached result keeps its line with its age |

The answer is cached in `.nogging/state/testing/ci-check.json` for
`testing.ci.cache_seconds`, so `doctor` calls `gh` at most once in that time, and a
refresh stops after 10 seconds. A pull-request run does not name its base branch, so
a pull request against another branch counts too; the check is meant to catch a
repository where test jobs do not run at all. It never changes `doctor`'s exit code.

## The nightly run

Where no CI runs tests, a timer does it. `init` and `update` always render
`systemd/nogg-nightly-<slug>.service` and `.timer`, because only a look at the real CI
runs can tell whether they are needed. Nothing runs until you enable the timer, and
`doctor` says when to, with a NOTE, where the CI result is `none` or no CI is configured
and no nightly run is recorded:

```bash
systemctl --user link "$PWD/systemd/nogg-nightly-<slug>.service"
systemctl --user enable --now "$PWD/systemd/nogg-nightly-<slug>.timer"
```

The timer fires at 01:17, 02:17, 03:17, 04:17 and 05:17 local time. Each firing is one
`nogg test nightly`, which goes through these steps and stops at the first that says so:

1. It exits at once when `testing.nightly.enabled` is false or a supervised session
   calls it. Nothing is recorded.
2. It skips when the CI result is `ran`. The cached result is used for
   `testing.ci.cache_seconds` and refreshed after that. An `unknown` result runs: you
   enabled the timer.
3. It fetches `testing.ci.branch`. If the fetch fails it tests the last known
   `origin/<branch>`, and the record says so. It skips a commit the last nightly record
   already holds, passed or failed, so a commit runs at most once.
4. It defers while the 1-minute load is above half the core count or a heavy slot is
   held. The 05:17 firing runs anyway, so a busy host still gets a run.
5. It updates the worktree at `<main>-nightly`, a sibling of the main checkout, with a
   forced detached checkout and `git clean -ffd`. Ignored files survive, so
   `node_modules` stays. The shared checkout and every Lead's worktree stay untouched:
   the fetch only moves `origin/<branch>`.
6. It runs `testing.nightly.setup`, then `nogg test full --nightly` in that worktree, at
   `Nice=15` and idle I/O priority. The suite and its `testing` block are those of the
   tested commit; `setup` comes from the main checkout, under the same deny rules as a
   stage.
7. It writes `.nogging/state/testing/nightly-last.json`: `run_id`, `at`, `status`, `head`,
   `seconds`, `log`, up to five names in `failed`, `offline` and `step`, which says how far
   the run got (`full`, `setup` or `worktree`). The run's whole log is kept beside it as
   `nightly-last.log`, because the stage's own log goes with the newest 20.

Every skip and deferral is one record of stage `nightly` in `runs.jsonl`, with its reason.
A firing the gates stopped exits 0; a run exits with its own code, so the unit shows a
failure. A run that waited `slot_wait_seconds` and got no slot tested nothing: it leaves
no nightly record, and the next firing tries again.

`nogg test full` is locked under `auto` for 3 days after a nightly record, since something
else is testing the branch.

**A failed run reaches you twice.** `doctor` prints a WARN, whether dispatch is on or not,
and a dispatch pass holds one non-urgent [digest](session-wake.md) item of kind
`nightly_failed`, naming the commit and the log. Both clear when a later run passes. The
commit stays tested, so to run it again, delete `nightly-last.json`. That is also how to
clear the WARN after CI starts running tests, because the nightly run then skips.

To stop using it, disable the timer, then remove the worktree with `git worktree remove
--force <main>-nightly`. `remove` names both.

## Exit codes

| Code | Meaning |
| --- | --- |
| the stage's own | the stage ran; 0 also for a skipped stage |
| 2 | a usage error |
| 75 | no heavy slot came free in time |
| 77 | refused: the full-suite lock, a claimed trigger, or a deny rule |

See [Configuration](https://jome92.github.io/nogging/configuration/#testing) for every key of the `testing` block.
