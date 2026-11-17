# nogg-bench

The impact benchmark for Nogging: it measures what a Nogging arm gains over a
plain coding agent on the same tickets. This package is **separate from
Nogging**. It imports nothing from it, reaches it only through its command
line (and the one usage helper process described in the change), is not in the
published npm package and is not copied by the installer. Design:
`openspec/changes/impact-benchmark/` (Decisions 1 to 17).

This file documents what exists today (BEN-001, BEN-004 and BEN-005). `run`
is added by BEN-002, which extends this README.

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

## The report (BEN-005)

```bash
bench/nogg-bench report --batch <batch>... --out bench/reports/<name>/
```

Reads `results/<batch>.jsonl` for each named batch, `results/review/*.jsonl`,
`prices.yaml`, `PREREGISTRATION.md` (the thresholds block) and the arm files of
the primary comparisons, and writes `report.md`, `runs.csv` and `metadata.json`
into `--out`. A refusal prints `report: refused: <file>: <field>: <message>` per
problem, exits 1 and writes nothing. Output is deterministic (no timestamps).
`--bench-dir` names another bench directory.

**Refused:** an invalid result or review line; two different preregistration
hashes among the non-smoke lines (named in the message; `--allow-mixed-preregistration`
reports them together anyway); a missing or invalid arm file for an arm of a
primary comparison; two paired arms whose `timebox_minutes` differ; two arms of
one vendor (same `agent.cli`) whose `model` or `effort` differ; a missing or
invalid `prices.yaml` or thresholds block.

**What is counted.** A run is counted in the tables unless it is a smoke run,
ended in `infra_error`, or is flagged `contamination_suspect`. The last two are
listed apart in `report.md`; smoke runs appear only in `runs.csv`. Every run, counted or not,
is in `runs.csv` (columns in `report.CSV_COLUMNS`, with `status`, `smoke`,
`counted_in_tables` and `excluded_because`).

**Pairing.** Tickets are paired when both arms of a comparison have a counted
run on them. With several seeds an arm's value on a ticket is the *majority pass*
(strictly more than half of its runs; an even split fails) and the *median cost*;
the spread between seeds is shown. Tables are per size class and overall.

**Tests.** McNemar's exact test on the discordant tickets for pass/fail; the
exact sign test on cost with ties dropped, both two-sided and implemented in
`nogg_bench/stats.py`. Cost is tokens times the list prices of
`prices.yaml` (USD per million input, output, cache-read and cache-write tokens,
with `source` URL and `date` per model). A model without a row has *unknown* cost,
never zero: the run's `cost_usd` is blank, `models_without_price` names the model,
a ticket with an unknown cost is left out of the sign test, and the cost per accepted
ticket is unknown. Add the row (and its source and date) to `prices.yaml`.

**Cost per accepted ticket** is the summed ticket cost (all paired tickets, accepted
or not) divided by the number of accepted tickets, under both definitions the
thresholds block allows: `tests_pass` (majority pass) and
`tests_pass_and_review_merge` (a run is accepted when it passed and its review says
`merge`; `merge-after-changes` does not count; a passing run without a review record
is not accepted and the report says how many there are). The block's
`accepted_ticket` decides which one the thresholds use.

**Thresholds** are evaluated as `met`, `not met` or `tie`. The target is no
difference (`not_worse`), a lead of `margin` points (`lead_by`) or equal cost per
accepted ticket (ratio 1). The verdict is `met` when the observation is at least
`minimum_effect` beyond the target, `not met` when it is at least that far short of it
and `tie` in between; exactly the minimum effect counts as an effect (so a
`not_worse` threshold with a difference of zero is a `tie`: neither shown met nor
shown missed). The cost ratio uses `minimum_effect.cost_ratio` the same way
(`met` at ratio <= 1/r, `not met` at >= r). `significance_level` annotates the
p-value as significant or not and does not change the verdict. A threshold with
nothing to evaluate (no paired ticket, unknown cost, no accepted ticket) is `unknown`
and says why. The reproducibility criterion (pass agreement over pairs of runs of one
arm on one ticket, and how many tickets exceed `max_cost_ratio`) is reported per arm.

**`metadata.json`** holds the bench commit (and those in the runs), every arm file
with its hash, settings (model, effort, agent version) and the prompt text and
hash, the `AGENTS.md` of each Nogging ref (read with `git show <ref>:AGENTS.md` in
the repository, or marked unavailable), the preregistration blob hash, model IDs,
image digests, usage-collector versions and the price table used. `report.md` also
lists measured runs that started before the preregistration's first commit when
git history shows one, and always states the deviation from real use: Nogging arms
plan without human approval.

## Blind review (`review-pack`)

Hidden tests say whether a diff passes; the review says whether a maintainer
would merge it. The reviewer must not know which arm wrote a diff.

```bash
bench/nogg-bench review-pack --batch <batch> --out /path/to/<pack>   # build
bench/nogg-bench review-pack --import <filled-sheet.csv> --key <key>  # import
```

**Build.** For the completed runs of `results/<batch>.jsonl` (other statuses are
not reviewed) the command writes `<pack>/items/<label>.md`, one per run, and
`<pack>/record-sheet.csv`. A label is four random characters, the order is
shuffled, and both come from the random source alone, not from the arm or the
run order. An item holds the task's issue text and the diff with the process
artefacts removed (`blind.py` lists them: `openspec/`, `.beads/`, `.nogging/`,
`.claude/`, `.codex/`, `.pi/`, `.agents/` at the repository root, `AGENTS.md` and
`CLAUDE.md` anywhere, Bead tokens, `Nogging-Writer:` and `Co-authored-by:` lines,
and the author, date and diffstat lines of commit text). Markdown lines and the
pull request count are in the result line and are left out on purpose. The
**key** (label to run ID) is written to `<pack>.key.json` next to the pack
directory, or to `--key`; it must lie outside the pack and must not reach the
reviewer. `diff_path` of a result line is read relative to `--runs-root` (default:
this bench directory). If a diff still holds any marker after anonymisation the
command writes nothing and names the run; the Product Owner decides what to do
with that run (it is never shown unblinded).

**Review procedure (for the reviewer).**

1. Open the pack directory only. Read `items/<label>.md` one by one in any
   order; do not look at the key, the results files or the git history.
2. For each item start a stopwatch, read the issue, then review the diff as you
   would a pull request for that project, with no help from the repository
   beyond what the item shows. Stop the stopwatch when you have decided.
3. Fill one row of `record-sheet.csv` per item: `merge_decision` is `merge`,
   `merge-after-changes` or `reject`; `critical`, `major`, `minor` are whole
   numbers of defects you found (0 for none); `review_minutes` is the stopwatch
   time in minutes, above zero (for example `6.5`); `comment` is free text.
   Leave no row empty and do not rename the columns.
4. Hand the sheet to the Product Owner. Do not try to guess the arm; if you
   think you recognise one, say so in the comment of that row.

**Import.** `--import` checks the header, that every row's item is in the key
and listed once, that every item of the key has a row, the decision, the
defect counts and the minutes, and runs the review record check. Only then does
it append one record per item to `results/review/<pack>.jsonl` (the `<pack>` is
the pack directory's name, kept in the key) with `run_id` taken from the key. One
bad row refuses the whole sheet and names the row and the value. A pack is not
imported twice. `validate` accepts the file afterwards.

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

`run`, the arm files for A, B and C,
`PREREGISTRATION.md` and the Harbor adapter arrive with BEN-002 to BEN-007.
