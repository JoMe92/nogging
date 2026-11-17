# nogg-bench

The impact benchmark for Nogging: it measures what a Nogging arm gains over a
plain coding agent on the same tickets. This package is **separate from
Nogging**. It imports nothing from it, reaches it only through its command
line (and the one usage helper process described in the change), is not in the
published npm package and is not copied by the installer. Design:
`openspec/changes/impact-benchmark/` (Decisions 1 to 17).

This file documents what exists today (BEN-001). `run`, `review-pack` and
`report` are added by BEN-002, BEN-004 and BEN-005, which extend this README.

## Run the suite

```bash
uv run --project bench --extra dev pytest bench/tests
```

or, with your own virtual environment, `pip install './bench[dev]'` and
`pytest bench/tests`. The suite is offline: no Docker daemon, no agent CLI, no
Harbor, no network. `scripts/test` and `nogg test` do not discover it, so run it
explicitly. There is no CI workflow for it yet: the planned `bench.yml` (path
filter `bench/**`, Python 3.11 and 3.13, actions pinned by SHA, then
`python -m pip install './bench[dev]'`, `python -m pytest bench/tests`,
`bench/nogg-bench validate`) could not be pushed because the delivery token
lacks the GitHub `workflow` scope; a follow-up adds it.

## The command

```bash
bench/nogg-bench validate                       # check every record under bench/
bench/nogg-bench validate bench/tasks/<id>      # or the paths you name
```

`bench/nogg-bench` runs the package from a checkout (system Python with PyYAML,
else `uv`). After `pip install ./bench` the same command is `nogg-bench`.

`validate` decides what a file is from where it lies, prints one line per
problem as `<file>[:<line>]: <field>: <message>` and exits non-zero when there
is any. It skips `bench/tests/` (its fixtures include invalid records) and
`bench/reports/`.

## Data layout

```text
bench/
  pyproject.toml, nogg-bench      package and wrapper
  src/nogg_bench/                 the package
  tests/                          pytest suite; tests/fixtures/{valid,invalid}/
  examples/                       fixture repository bundle + three example tasks
  tasks/<id>/                     task.yaml, issue.md, hidden/   (Product Owner, BEN-006)
  arms/<arm>.yaml, arms/prompts/  arm files and prompt templates (BEN-002)
  results/<batch>.jsonl           one result line per run (BEN-002)
  results/review/<pack>.jsonl     review records (BEN-004)
  reports/<name>/                 report.md, runs.csv, metadata.json (BEN-005)
  prices.yaml                     list prices (BEN-005)
  PREREGISTRATION.md              prose plus the thresholds block (BEN-006)
```

## Record formats

Every record has `schema: 1` and rejects unknown fields. The rules live in one
place, `src/nogg_bench/schema.py`; a task that needs a new field adds it there
with a test and never writes an unvalidated field.

| Record | File | Kind is decided by |
| --- | --- | --- |
| task | `tasks/<id>/task.yaml` | the name `task.yaml` |
| arm | `arms/<arm>.yaml` | a parent directory called `arms` |
| result line | `results/<batch>.jsonl` | a `.jsonl` file directly in `results/` |
| review record | `results/review/<pack>.jsonl` | a `.jsonl` file in a `review/` directory |
| thresholds block | fenced `yaml` block in `PREREGISTRATION.md` | the name `PREREGISTRATION.md` |

**Task** (`task.yaml`): `id` (kebab, equal to the directory name), `repo` (clone
URL, or a bundle path under `bench/` for examples), `base_commit` (full SHA),
`language`, `license`, `issue` (file next to `task.yaml`, the text exactly as the
agent sees it), `issue_url` and `fix_pr_url` (provenance, never shown to the
agent), `issue_closed_at`, `size_class` (`small` 1 to 2 files, `medium` 3 or
more, `large` a larger feature or refactoring), `environment` (`image`, `setup`
commands, `test_command` containing `{tests}`, `test_timeout_seconds`),
`hidden_tests` (`patch` under `hidden/`, `fail_to_pass`, `pass_to_pass`
identifiers) and `curation` (`status` of `example`, `candidate` or `accepted`;
`accepted` also needs `hidden_tests_verified_by` and `verified_on`). A test
identifier cannot be in both lists. `accepted` means the Product Owner ran the
hidden tests against `base_commit` (fail-to-pass fail, pass-to-pass pass) and
against the original fix (all pass). Only the Product Owner sets `accepted`.

**Arm** (`arms/<arm>.yaml`, the file name is the arm's `id`): `id` (one capital
letter), `label`, `kind` (`claude-code`, `codex`, `nogging`), `agent`
(`cli`, `version`), `model`, `effort`, `timebox_minutes`, `prompt` (path next to
the arm file, usually `prompts/<x>.md`), `disabled_tools`, `credentials` and, for
a `nogging` arm, `nogging_ref` plus optional `switches` (shape only). Credentials
are references: `{env: <VARIABLE NAME>}` or `{dir: <credential directory>}`,
exactly one. A value pasted into `env` is refused because it is not a variable
name. Never put a credential value in any file.

**Result line**: identity (`run_id`, `batch`, `arm`, `task`, `seed`,
`size_class`, `source` = `bench` or `harbor:<dataset>`, `started_at`, `ended_at`,
`wall_clock_seconds`), outcome (`status` of `completed`, `timeout`,
`agent_error`, `infra_error`; `reason` for `infra_error`; `passed`; `tests` with
`fail_to_pass` and `pass_to_pass` maps from identifier to boolean;
`hidden_paths_overwritten`; `contamination_suspect`), size (`diff_stats`,
`diff_path`, `markdown_lines`, `pr_count`), `usage` (per model `input`,
`output`, `cache_read`, `cache_write`), `usage_collector` (`helper_version`,
`nogging_commit`) and `provenance` (`arm_file_hash`, `prompt_hash`,
`agent_cli_version`, `nogging_ref` or null, `image_digest`, `bench_commit`,
`preregistration_hash` as a git blob hash, null only on a smoke run, and
`smoke`). `passed` must equal "every listed test passed". An `infra_error` line
may have empty `tests` and `usage` and null `diff_stats` and `diff_path`; it can
never have `passed: true`. Result lines are appended, never rewritten.

**Review record**: `pack`, `item` (the random label), `run_id`, `merge_decision`
(`merge`, `merge-after-changes`, `reject`), `defects` (`critical`, `major`,
`minor` counts), `review_minutes` (above zero), `comment`, `reviewed_at`.

**Thresholds block**: one fenced `yaml` block in `PREREGISTRATION.md` whose top
level has a `thresholds` key (exactly one such block). Keys: `primary_comparisons`
(list of `{treatment, control}` arm IDs), `accepted_ticket`
(`tests_pass` or `tests_pass_and_review_merge`, the definition for the cost
metric), `thresholds` (list of `{id, comparison, metric, size_class,
requirement, margin}`; `metric` is `hidden_tests_passed` or
`cost_per_accepted_ticket`; `size_class` is `all` or a size class; `requirement`
is `not_worse`, or `lead_by` with `margin` in percentage points for
`hidden_tests_passed` only; each comparison must be a primary comparison),
`minimum_effect` (`pass_rate_points`, `cost_ratio`; a smaller difference is a
tie), `significance_level`, and `reproducibility` (`min_pass_agreement`, the
share of tickets on which two runs of one arm agree on pass or fail, and
`max_cost_ratio`, how far apart their costs may be). `report` (BEN-005)
evaluates each threshold as met, not met or tie.

## For BEN-002, BEN-004 and BEN-005

- **Validate before you write.** `nogg_bench.schema.check_task`, `check_arm`,
  `check_result`, `check_review` and `check_thresholds` take parsed data and
  return a list of `Problem(file, field, message)`; empty means valid. Build a
  record, check it, then write it.
- **Read through `nogg_bench.records`:** `load_yaml`, `read_jsonl` (yields line
  number and record), `thresholds_block` and `load_thresholds` (the checked block
  of a preregistration). They raise `RecordError`, whose `problem` names the file.
- **Whole-tree checks** go through `nogg_bench.validate.validate(paths, bench_dir)`;
  `kind_of` and `discover` expose the location rules.
- **Add a subcommand without touching `cli.py`:** create `nogg_bench/run.py`
  (BEN-002), `review_pack.py` (BEN-004) or `report.py` (BEN-005) with
  `add_parser(subparsers)` that calls `set_defaults(handler=fn)`; `fn(args)` returns the
  exit code. Until the module exists the command answers "not available in this
  build yet" and exits 2.
- **Fixtures** for every kind, valid and invalid, are in
  `tests/fixtures/{valid,invalid}/` in the layout above (so `validate
  tests/fixtures/valid` passes and `validate tests/fixtures/invalid` fails). The
  valid result fixture holds four lines (arm A completed and passed, arm C
  completed and failed, arm A timed out with an overwritten hidden path and a
  contamination flag, arm B `infra_error`); the valid review fixture holds two
  records. Extend them in your own task's tests rather than editing these.
- **Everything is offline in tests.** Stub `docker` and the agent CLIs on `PATH`,
  inject the clock, and use temporary directories.

## Running arms: `run`

```bash
bench/nogg-bench run --batch pilot --arm A --arm B --arm C \
    --task <id> --task <id> --seed 1 --seed 2        # every combination, once
bench/nogg-bench run --batch try --smoke --arm A --task example-small-slugify --seed 1
```

`run` runs each combination of `--arm`, `--task` and `--seed` in a fresh
container and appends one result line per run to `results/<batch>.jsonl`; the
run's diff, transcripts, test output and log go to `results/runs/<run_id>/`.
A combination that already has a line in the batch file is skipped, so an
interrupted batch is resumed by running the same command again; `--rerun` runs
it anyway under a new `run_id` (`...-r2`). Exit status: 0 when every run left a
line without `infra_error`, 1 when one did not, 2 when the command refused to
start.

**Before any container starts**, `run` refuses (and names the reason):

- arms whose `timebox_minutes` differ, or same-vendor arms (every Claude-based
  arm) whose `model` or `effort` differ;
- without `--smoke`: a missing, uncommitted or changed `bench/PREREGISTRATION.md`,
  one without a valid thresholds block, and any task whose `curation.status` is
  not `accepted`. The result line records the preregistration's blob hash;
- `--agent-stub` without `--smoke`.

A `--smoke` run works on example and candidate tasks without a preregistration,
carries `provenance.smoke: true`, and no report table counts it.

**One run, in order** (design Decision 7):

1. The arm's credentials are staged (below), the task image is resolved (its
   ID is the `image_digest`), and the repository is cloned on the host and cut
   to `base_commit`: one branch `main` at the base, no tag, no remote, no
   reflog, no unreachable commit. `run` checks this before it goes on.
2. A container starts with **nothing mounted** (`docker run --entrypoint sleep
   ... infinity`). The repository, the brief (`/work/brief.md`: the arm's prompt
   with the issue text, the agent's only input) and the agent scripts are
   copied in; the task's `setup` commands run; git and `timeout` are installed
   if missing; the agent CLI is installed at the arm's pinned version.
3. The agent runs under `timeout <timebox>` from `/work/repo` with web tools
   disabled: arm A as `claude -p` first in `--permission-mode plan`, then
   `--continue` to implement; arm B as `codex exec` with `tools.web_search`
   off; a `nogging` arm through the driver (below). Exit 124/137 is `timeout`,
   another non-zero exit `agent_error`.
4. The diff against the base (committed, uncommitted and new files) is saved,
   and `~/.claude/projects` and `~/.codex/sessions` are copied out.
5. **Only now** the hidden patch is copied in. Every path it writes is first
   put back to the base version, so an agent's change to a hidden test is
   overwritten and listed in `hidden_paths_overwritten`. The test command runs
   with the task's timeout; a test passes only when reported `PASSED` and
   nothing else. The run passes when every fail-to-pass and pass-to-pass test
   passes.
6. Tokens are counted by the usage helper (below), the transcripts are scanned
   for web tool calls and for `issue_url` or `fix_pr_url`
   (`contamination_suspect`), the line is validated and appended, and the
   container is removed.

An infrastructure failure at any step (image, clone, container start, setup,
install, diff, hidden patch, usage helper) still appends a line, with
`status: infra_error` and the `reason`.

**Credentials** (Decision 8). An arm names them by reference only:
`credentials.env` is the name of a host environment variable holding an API
key, `credentials.dir` a host directory holding a subscription login (copied
into `~/.claude` or `~/.codex` in the container). `run` stages the value in a
private `0700` temporary directory outside `results/`, as a `0600` env file
passed with `docker exec --env-file` to the agent's process only, or as a
`0600` copy of the directory that is deleted from the container right after
the agent ends; the staging directory is removed when the run ends. No value is
put on a command line (a docker call that would carry one is refused), and the
run log, the diff, the test output and the copied transcripts are redacted.
Setup commands and hidden tests never see the credential.

**Token usage** (Decision 10). `nogg_bench/usage_helper.py` is the one place
that knows Nogging's token-usage adapters (`scripts/lib/token_usage_adapters.py`
of the checkout given by `--nogging-checkout`, default: the repository holding
`bench/`). `run` starts it isolated (`python3 -I`) on the copied transcripts of
every arm; it keeps each usage event's last revision and returns per model
`input` (uncached input, the same way for both vendors), `output`,
`cache_read` and `cache_write`, plus the Nogging commit it read
(`usage_collector`). When it cannot load the adapters the run is
`infra_error` naming the helper, never a zero count. `tests/test_usage.py`
fails when the adapters move; then only the helper changes.

**Arm C, the driver** (`nogg_bench/driver.py`, standard library only, run
inside the container). It plays the Product Owner: installs Nogging from the
host checkout's tree at `nogging_ref` (`node bin/cli.js init`, then `bd init`
if needed) and commits that as the diff base, so Nogging's own files are not
counted as work; gives the repository a `develop` branch and a local bare
`origin` seeded from the truncated history (Nogging's worktrees branch from
`origin/develop`; it holds no commit after the base); starts a planning session
with the brief as kickoff, waits for its done signal, merges the plan branch
into `develop` without an approval step and runs `nogg materialize`; starts a
`--full-access` Lead on the first ready Bead with `kickoff --change`, waits for
its done signal or the timebox; then merges every implementation branch into
`develop` (their number is `pr_count`), stops its sessions and writes
`state.json`. Every launch passes the arm's `--agent`, `--model` and
`--effort`. The container needs node, tmux, python3, openspec, and the host's
`bd` and `dolt` binaries, which `run` copies in (same CPU architecture). A
planning session that blocks, or a Lead that signals `blocked`, ends the run as
`agent_error` with the signal's reason; the report states that planning ran
without human approval.

**Testing `run`.** `tests/test_run.py` and `tests/test_driver.py` run whole
runs offline against `tests/stubs/docker`, a stub on `PATH` that records every
argv and emulates the container in a directory, with stub agent CLIs that write
transcript fixtures and diffs. One large test runs arm A's stub agent on
`example-small-slugify` in a real container:

```bash
NOGG_BENCH_DOCKER=1 uv run --project bench --extra dev pytest bench/tests/test_run.py -k large
```

It needs a Docker daemon and network access for the image and `pip install
pytest`; CI does not set the variable. `--agent-stub <executable>` (with
`--smoke` only) copies an executable in as the agent CLI instead of installing
it; that is how the large test and a manual smoke run avoid a model call.

**Arms A, B and C** (`arms/`) start from the `complex` entries of `scripts/nogg
models`: `claude-opus-5-5` at effort `high` for A and C, `gpt-6.1-sol` at
effort `low` for B, all with a 90-minute timebox and API-key credentials. The
Product Owner confirms or changes model, effort, timebox and the credential
mode (open question 2) before the pilot (BEN-007).

## Example tasks and the fixture repository

`examples/fixture-repo.bundle` is a git bundle of a tiny Python library
(`miniutil`) with three fix commits. `examples/tasks/` holds three tasks against
it, one per size class, each with `curation.status: example`, a real hidden test
patch and fail-to-pass and pass-to-pass tests. The hidden tests are **not** in
the repository history. `tests/test_examples.py` checks that they fail on the
base commit and pass on the fix commit, inside the unpacked bundle.

`examples/build_fixture_repo.py` rebuilds the bundle and the hidden patches
byte for byte (fixed identities and dates) and prints the base commits written
in the `task.yaml` files.

A note for a task author (BEN-006): the `{tests}` in `test_command` is replaced
by the identifiers. `pytest` stops the whole run when one identifier does not
exist or a named test file fails to import, so the pass-to-pass tests of that
run are then unknown. Write hidden tests whose module imports succeed at the
base commit (see the lazy import in the large example), or run whole test files.

## Not yet here

`review-pack`, `report`, `prices.yaml`, `PREREGISTRATION.md` and the Harbor
adapter arrive with BEN-003 to BEN-007.
