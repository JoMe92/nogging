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

## Exit codes

| Code | Meaning |
| --- | --- |
| the stage's own | the stage ran; 0 also for a skipped stage |
| 2 | a usage error |
| 75 | no heavy slot came free in time |
| 77 | refused: the full-suite lock, a claimed trigger, or a deny rule |

See [Configuration](https://jome92.github.io/nogging/configuration/#testing) for every key of the `testing` block.
