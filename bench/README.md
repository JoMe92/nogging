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
it anyway under a new `run_id` (`...-r2`), and `--retry-infra` reruns only the
combinations whose lines are all `infra_error`. A batch holds either smoke runs
or measured runs, never both. Exit status: 0 when every run left a
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
   copied in; the task's `setup` commands run as root; git and `timeout` are
   installed if missing; the agent CLI is installed at the arm's pinned version;
   an unprivileged user `bench` is created and given `/work`.
3. The agent runs as `bench` (Claude Code refuses unattended permission modes
   as root) under `timeout <timebox>` from `/work/repo` with web tools
   disabled: arm A as `claude -p` first in `--permission-mode plan`, then
   `--continue` to implement; arm B as `codex exec` with `tools.web_search`
   off; a `nogging` arm through the driver (below). Exit 124 (or 137 at the
   limit) is `timeout`, another non-zero exit `agent_error`. Then the container
   is restarted, which kills every process the agent left behind (a tmux
   server, a background job) and keeps its file system, and staged credential
   files are deleted.
4. The diff against the base (committed, uncommitted and new files) is saved,
   and `~/.claude/projects` and `~/.codex/sessions` are copied out, first into a
   scratch directory, then redacted and without symlinks into the run
   directory.
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
key, `credentials.dir` a host directory holding a subscription login. From that
directory only the agent CLI's credential file is taken (`.credentials.json`
for `claude`, `auth.json` for `codex`), so pointing it at `~/.claude` does not
copy your own transcripts or history into the container. If the agent refreshes a
subscription token during the run, the refreshed file is read back before it
is deleted and its tokens are redacted too; a refresh may rotate the token and
sign the host's own login out, so give the benchmark its own login. `run` stages the value in a
private `0700` temporary directory outside `results/`, as a `0600` env file
passed with `docker exec --env-file` to the agent's process only, or as a
`0600` copy of the directory that is deleted from the container right after
the agent ends; the staging directory is removed when the run ends. No value is
put on a command line (a docker call that would carry one is refused), and the
run log, the diff, the test output, the copied transcripts and every `reason`
are redacted (before any truncation). The secrets are the env value, a
credential file's whole content and its JSON values under token, key, secret,
password or credential keys. Setup commands and hidden tests never see the
credential.

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
with the brief as kickoff, waits for its done signal or for it to go idle with
a new change on a plan branch (the v3.6.0 planning prompt has no signal step),
merges the plan branch into `develop` without an approval step and runs `nogg
materialize` (a refusal there is tolerated); starts a
`--full-access` Lead on the first ready Bead with `kickoff --change`, waits for
its done signal or the timebox; then merges origin's `develop` and every
implementation branch into `develop`, counts `pr_count` from the forge
stand-in's records (below), stops its sessions and writes
`state.json` (also right after the install, so a killed driver still leaves
its diff base). `state.json` is agent-writable: `run` checks every field, and
a missing or malformed one makes the run `agent_error` with `pr_count` 0. The
Nogging tree copied in never holds `bench/` (excluded from the archive and
checked), so a later ref cannot hand the agent the hidden tests. Every launch passes the arm's `--agent`, `--model` and
`--effort`. The container needs node, tmux, python3, openspec, and the host's
`bd` and `dolt` binaries, which `run` copies in (same CPU architecture). A
planning session that blocks, or a Lead that signals `blocked`, ends the run as
`agent_error` with the signal's reason; the report states that planning ran
without human approval.

**Container options, the same for every arm** (Decision 20,
`docker.container_options()`). Every container starts with

```
--security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt systempaths=unconfined
```

and nothing else beyond `--init`: no `--privileged`, no `--cap-add`, no device,
no mount, no host namespace. Nogging's execution sandbox
(`scripts/openspec-sandbox`) calls `unshare --user --mount`; Docker's default
seccomp profile refuses `unshare` and `mount` to a process without
`CAP_SYS_ADMIN`, and its default AppArmor profile denies `mount`. The sandbox's
full call also mounts a fresh `/proc` (`--pid --fork --mount-proc`), which Docker
refuses while it masks paths under `/proc`; `systempaths=unconfined` lifts that
mask. Checked against a real container: with Docker's defaults `unshare` fails,
with the first two options `mount /proc` still fails, and with all three the
full call succeeds. Lifting those
profiles lets the unprivileged user `bench` create its own user and mount
namespace, where it holds capabilities over that namespace only; in the
container it gains none. Arms A and B get the same options although they need
none, so the arms differ in their agent and not in their container. The price:
the agent's processes are not syscall-filtered, so the isolation of a run is the
container's namespaces, its default capability set and the absence of any mount,
not seccomp. `Docker.call` refuses any call holding `--privileged` or
`--cap-add`. The options are recorded in each result line
(`provenance.container_options`; `validate` refuses a line that lists
`--privileged`) and in the report's `metadata.json`
(`container_options_in_runs`: one entry when all runs had the same). A change
to them is one constant, `docker.SECURITY_OPTIONS`, and needs a smoke run that
proves it necessary.

**The local forge stand-in** (`nogg_bench/forge.py`, standard library only).
The v3.6.0 Lead ends with a pull request, and the container has no forge and
no token. For a `nogging` arm `run` copies this file in as `/usr/local/bin/gh`.
It answers four calls, against the driver's bare `origin` (`/work/origin.git`):

| Call | Answer |
| --- | --- |
| `gh pr create` | checks that base and head are branches of the origin, writes `/work/forge/pulls/<n>.json` (title, body, base, head, head commit, state), prints the pull request's URL (`https://forge.invalid/...`, never resolvable) |
| `gh pr view` | the recorded pull request, as text or `--json <fields>` |
| `gh pr checks` | one check, `bench-forge`, passed |
| `gh pr merge` | merges head into base inside the bare origin (git plumbing, no push), marks the record `MERGED`; the head branch is kept |

Every other call (`pr list`, `auth`, `api`, `repo`, an unknown flag, `--web`,
`--repo`) exits 1 with `refused` on stderr. It refuses an `origin` that is not
an absolute path to a local bare repository before any other step, runs only
local git commands on it, imports no network module and reads no token. Each
call is logged to `/work/forge/calls.jsonl` by its subcommand words only (never
an argument value), so a smoke run shows which calls a Lead made and which were
refused. After the agent ended, `/work/forge` is copied to
`results/runs/<run_id>/forge/`, redacted and without symlinks like the
transcripts. `pr_count` is the number of recorded pull requests whose head or
merge commit is in the integrated `develop` and not in the diff base; a pushed
branch without a pull request is still merged and measured but not counted.
The records are agent-writable, so the driver checks each field it uses.

Still to prove with real smoke runs (`--smoke`, not counted in any report): that
arm C finishes with a done signal in a real container, and that these two
options are enough for the whole sandbox call of v3.6.0 (`--pid --fork
--mount-proc`).

**Testing `run`.** `tests/test_run.py` and `tests/test_driver.py` run whole
runs offline against `tests/stubs/docker`, a stub on `PATH` that records every
argv and emulates the container in a directory, with stub agent CLIs that write
transcript fixtures and diffs. `tests/test_forge.py` covers the stand-in's
answers and refusals. One large test runs arm A's stub agent on
`example-small-slugify` in a real container; two in `test_driver.py` check the
container options against the sandbox's `unshare` calls and run arm C's smoke
run (that one also needs the arm's credential):

```bash
NOGG_BENCH_DOCKER=1 uv run --project bench --extra dev pytest bench/tests/test_run.py bench/tests/test_driver.py -k large
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
image digests, the container options of the runs, usage-collector versions and the
price table used. `report.md` also
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

## The Harbor adapter (BEN-003)

The same arms run on Harbor datasets such as FeatureBench through a Harbor
agent loaded by import path. Harbor 0.26.0 is pinned in the `harbor` extra
(its agent interface — `BaseAgent` with the `setup`/`run` hooks, environment
`exec`/`upload`/`download`, the agent's `logs_dir`, and the verifier's
`rewards` mapping — is what the adapter is written against); Harbor itself
needs Python >= 3.12, so the extra is empty on 3.11.

```bash
uv run --project bench --extra harbor harbor run \
  --agent nogg_bench.harbor:BenchAgent \
  --dataset <harbor-dataset> --agent-name nogg-bench \
  --output-dir bench/results/harbor
```

The wrapper class `nogg_bench.harbor:BenchAgent` takes everything else from
the environment, because Harbor's options belong to the model, not to the
benchmark:

| Variable | Meaning |
| --- | --- |
| `NOGG_BENCH_ARM` | path of the arm file; loaded and validated when the agent is constructed, so an invalid arm fails before any install call |
| `NOGG_BENCH_BATCH`, `NOGG_BENCH_TASK`, `NOGG_BENCH_SEED`, `NOGG_BENCH_SIZE_CLASS` | the result line's identity |
| `NOGG_BENCH_RESULTS_DIR` | where `<batch>.jsonl` and `runs/<run_id>/` go |
| `NOGG_BENCH_SOURCE` | the result line's source, `harbor:<dataset>` (default `harbor:featurebench`) |
| `NOGG_BENCH_NOGGING_CHECKOUT` | host checkout: Nogging archive source for a `nogging` arm, and the usage helper's adapters |
| `NOGG_BENCH_BENCH_DIR` | the bench directory, for the bench commit and the preregistration blob hash |
| `NOGG_BENCH_PREREGISTRATION_HASH` | blob hash of the committed `bench/PREREGISTRATION.md`; a measured run without it is refused |
| `NOGG_BENCH_SMOKE` | `1` marks the run as a smoke run, kept out of every report table |
| `NOGG_BENCH_VERIFIER_CMD` | the dataset's verifier command; its stdout must be a JSON mapping of test name to reward, and every reward must be `1` for a pass |
| `NOGG_BENCH_DIFF_BASE` | the diff base inside the task repository (default `HEAD`) |

The order of one Harbor run: install the arm's agent into the environment
(for a `nogging` arm, Nogging at the arm's `nogging_ref` and `bd`/`dolt`),
upload the brief (the arm's prompt with the task instruction as `{issue}`),
run the agent under the arm's timebox as the unprivileged user, copy the
diff and both transcript directories out, count the transcripts through the
usage helper, then run the verifier — Harbor's verdict decides `passed`, the
adapter only maps it — and append one result line with
`source: harbor:<dataset>`. Credentials stay Harbor's business: the adapter
moves none, Harbor's own auth resolution and network policy supply and
constrain the agent's model access.

**Choosing a FeatureBench subset.** Point `--dataset` at the FeatureBench
split you want and restrict it with Harbor's task filters to the tickets the
Product Owner curated in `bench/tasks/`, so every measured Harbor run pairs
with a `bench` run of the same ticket: pick tasks whose identifiers appear
in the curated task IDs, keep the size class of the Harbor task metadata in
the `NOGG_BENCH_SIZE_CLASS` you pass, and run the same arm/seed grid as the
batch you are extending. A single proof run for BEN-007 is one task, arm A,
seed 1, `NOGG_BENCH_SMOKE=1`.

## Not yet here

`PREREGISTRATION.md` arrives with BEN-006; the first measured Harbor runs
with BEN-007.
