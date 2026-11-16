## Context

The Product Owner's roadmap (Rev 16, 2026-11-16, kept outside the repository) orders a benchmark
before any new Nogging feature. Phase 0 builds it and measures the baseline. Its constraints, taken
over unchanged:

- `bench/` is its own Python package with pytest tests. It uses `scripts/nogg` only through the
  command line, never through imports, so the later split of the monolith does not touch it.
- Token counts come from Nogging's existing usage ledger. For arms A and B the same collector reads
  the Claude Code and Codex session data.
- Hidden tests live outside the container and are applied only after the agent run has ended.
- The Product Owner curates the tasks. An agent may propose candidates; the selection and the check
  of the hidden tests stay manual, or the benchmark is open to attack.
- No Nogging production code changes in this phase.

Arms (roadmap table): A Claude Code with plan mode, no Nogging (control); B Codex, no Nogging
(second-vendor control); C Nogging v3.6.0 unchanged (baseline); D Nogging with the new switches
(target, from Phase 1 on); E D with one switch off (ablation). Phase 0 measures A, B and C. D and E
need switches that do not exist yet; the arm format must be able to describe them later.

Metrics (roadmap table): hidden tests passed (primary); cost per accepted ticket (primary); merge
decision and review defects from a blinded review; wall-clock time from start to pull request;
human review minutes; Markdown lines and number of pull requests per ticket.

## Goals / Non-Goals

**Goals**

- A reproducible run of one arm on one ticket, isolated in a container, that leaves one result
  line whatever happens.
- Contracts that let BEN-002, BEN-004 and BEN-005 be built in parallel once BEN-001 is merged.
- Measurements the Product Owner can publish: prompts, versions, model IDs, effort levels and every
  run, failed ones included.
- A preregistration that is fixed, and provably fixed, before the first measured run.

**Non-Goals**

- Any change to Nogging's behaviour, configuration or shipped files.
- Arms D and E (they need Phase 1 to 3 switches).
- SWE-bench Pro runs (the adapter makes them possible; running them is later).
- Choosing repositories, tickets or thresholds. That is the Product Owner's work in BEN-006.
- A `nogg bench` subcommand inside `scripts/nogg`.

## Decisions

### Decision 1: What "no production code" means here

Production code is everything Nogging ships or runs as itself: `scripts/`, `bin/`, `templates/`,
`.claude/`, `.codex/`, `.pi/`, `.agents/`, `.nogging/` (configuration, prompts, profiles),
`package.json` and the docs site under `docs/`. This change writes only:

- `bench/` (all of the benchmark);
- one new CI workflow, `.github/workflows/bench.yml`, filtered to `bench/**`;
- the feature-freeze section in `AGENTS.md` (written by this planning session, Decision 15).

`package.json`'s `files` whitelist does not list `bench/`, and `bin/lib/manifest.js` does not
mention it, so it is neither published nor installed. A Lead that finds it must touch a file outside
this list records a blocking discovery instead.

### Decision 2: The command is `bench/nogg-bench`, not `nogg bench`

The roadmap writes `nogg bench validate|run|review-pack|report`. A subcommand in `scripts/nogg`
would be a production change and would couple the two. So the package installs a console script
`nogg-bench`, and `bench/nogg-bench` is a small executable wrapper that runs it from a checkout
(`python3 -m nogg_bench` with `bench/src` on the path, or through `uv run --project bench`). Every
spec scenario and task uses `nogg-bench`. An alias in `scripts/nogg` can follow after the baseline
report, as an ordinary planned change.

### Decision 3: Package layout and how its tests run

```text
bench/
  pyproject.toml          # package nogg-bench, Python >= 3.11, runtime dep PyYAML,
                          # dev extra pytest, optional extra harbor (pinned)
  nogg-bench              # executable wrapper (Decision 2)
  README.md               # how to validate, run, review and report; the data layout
  src/nogg_bench/         # the package
  tests/test_*.py         # pytest; fixtures under tests/fixtures/
  tasks/<id>/             # task.yaml, issue.md, hidden/ (Decision 5)
  arms/<arm>.yaml         # arm files (Decision 6)
  examples/               # fixture repository bundle for the three example tasks
  results/<batch>.jsonl   # one line per run, committed raw data (Decision 9)
  reports/<name>/         # report.md, runs.csv, metadata (Decision 13)
  prices.yaml             # list prices per model with source and date (Decision 13)
  PREREGISTRATION.md      # written by the Product Owner in BEN-006 (Decision 11)
```

Tests run with `uv run --project bench --extra dev pytest bench/tests/<file>` (or an equivalent
virtual environment with the dev extra). The host has no system pytest, and the package must not
depend on one. `scripts/test` and `nogg test` do not discover `bench/tests/`, so every task's
`Check:` names its pytest files explicitly. The new CI workflow installs the package with its dev
extra and runs `pytest bench/tests` on Python 3.11 and 3.13 when `bench/**` changes; it pins its
actions by SHA as `nogging-validate.yml` does.

### Decision 4: The shared contracts land first, in BEN-001

To let the runner (BEN-002), the review pack (BEN-004) and the report (BEN-005) be built at the same
time, BEN-001 defines and validates every on-disk record they exchange, each with a `schema: 1`
field:

| Record | File | Written by | Read by |
| --- | --- | --- | --- |
| task | `bench/tasks/<id>/task.yaml` | Product Owner (BEN-006) | run, adapter, review-pack, report |
| arm | `bench/arms/<arm>.yaml` | BEN-002 (A, B, C) | run, adapter, report |
| result line | `bench/results/<batch>.jsonl` | run, adapter | review-pack, report |
| review record | `bench/results/review/<pack>.jsonl` | review-pack import | report |
| thresholds block | fenced `yaml` block in `bench/PREREGISTRATION.md` | Product Owner | report |

`nogg-bench validate [<path>...]` validates each file by its location (or all of `bench/` with no
argument), prints one line per problem naming the file and the field, and exits non-zero on any
problem. BEN-001 also ships fixture records of every kind, so BEN-002, 004 and 005 test against the
same samples. A later task that needs a new field adds it to the schema with a test; it never
writes an unvalidated field.

### Decision 5: The task format and curation status

`task.yaml` fields:

- `id` (kebab, equal to the directory name), `repo` (clone URL, or a bundle path under
  `bench/examples/` for examples), `base_commit` (full SHA), `language`, `license`;
- `issue` (a path to `issue.md`, the issue text exactly as the agent sees it), `issue_url` and
  `fix_pr_url` (provenance; never shown to the agent), `issue_closed_at` (for the training-cutoff
  check);
- `size_class`: `small` (1 to 2 files), `medium` (3 or more files), `large` (larger feature or
  refactoring), as the roadmap defines them;
- `environment`: the base image and the setup commands that install dependencies at
  `base_commit`, plus the test command template and a test timeout;
- `hidden_tests`: `patch` (path under `hidden/`, the test changes of the original pull request),
  `fail_to_pass` and `pass_to_pass` (test identifiers);
- `curation`: `status` (`example`, `candidate` or `accepted`), and for `accepted` also
  `hidden_tests_verified_by` and `verified_on`.

`accepted` means the Product Owner has run the hidden tests against `base_commit` (the fail-to-pass
tests fail, the pass-to-pass tests pass) and against the original fix (all pass), and records who
and when. `validate` refuses an `accepted` task without those two fields and refuses any
`fail_to_pass` identifier that is also in `pass_to_pass`. An agent that proposes candidates writes
`status: candidate` only; flipping to `accepted` is the Product Owner's commit. A measured run
refuses a task that is not `accepted` (Decision 11), so an unreviewed candidate never enters the
data.

The three example tasks (one per size class, `status: example`) run against a small fixture
repository shipped as a git bundle in `bench/examples/`, so tests and smoke runs need no network.

### Decision 6: Arm files and what "same model" means

An arm file names `id` (A, B, C, later D, E), a label, a `kind` (`claude-code`, `codex` or
`nogging`), the agent CLI and its pinned version, `model`, `effort`, `timebox_minutes`, the prompt
template (stored as a file under `bench/arms/prompts/`), the tools it disables (web search and
fetch, Decision 7), and the credential reference (Decision 8). A `nogging` arm also names
`nogging_ref` (`v3.6.0` for C), the agent Nogging launches, and, for D and E later, the switch
values; Phase 0 validates that field's shape only.

The roadmap asks for the same model, effort level and timebox in all arms. A and B are different
vendors, so "same model" holds within a vendor: every Claude-based arm (A, C, later D and E) uses
the same model and effort, and B uses the matching Codex tier; the timebox is the same everywhere.
`report` refuses to pair two arms whose timeboxes differ, or two same-vendor arms whose model or
effort differ, and names the field. Inside arm C every Nogging session (planner, Lead,
specialists) launches with the arm's model and effort as explicit launch flags, so Nogging's tier
routing cannot pick another model.

### Decision 7: Isolation and the hidden tests

One run is one fresh container from the task's environment image:

1. The repository is checked out at `base_commit` with every later ref and every remote removed,
   so the fix is not in the container's history.
2. The arm's agent starts with the issue text as its only brief and the arm's tool restrictions
   (web search and web fetch disabled where the agent supports it). For a `nogging` arm, a
   bench-owned driver inside the container plays the Product Owner: it initialises Nogging from
   `nogging_ref`, starts a planning session whose kickoff is the issue text and says that the issue
   is the complete brief and needs no approval, then starts a `--full-access` Lead for the planned
   change, and waits for the Lead's done signal. Planning without human approval differs from real
   use; the report states it.
3. The agent ends by exiting, by a done signal, or by the timebox, after which the run stops it.
4. The run saves the diff against `base_commit` (committed and uncommitted, new files included)
   and copies the agent's transcript directories out.
5. Only now are the hidden test files copied into the container, overwriting any agent change to
   the same paths (recorded in the result), and the test command runs with the task's timeout.
6. Pass means every `fail_to_pass` test passes and every `pass_to_pass` test passes.

No hidden test path is mounted into, or reachable from, the container before step 5; a test checks
the container's mount and copy calls for this. Network egress cannot be closed completely while the
agent needs its model API. The run therefore scans the transcripts for web tool calls and for the
`issue_url` or `fix_pr_url` and marks such a run `contamination_suspect`; the report lists those
runs separately. A tighter egress allow-list depends on the Docker host (open question 4).

### Decision 8: Credentials

The arm file names how its agent authenticates by reference only: an environment variable name
for an API key, or a credential directory for a subscription login. The run passes the value into
the container through an environment file or a read-only mount created with mode `0600` and removed
after the run. No credential appears on a command line, in a result line, in a log, in a report or
in a fixture; the run's log writer redacts the configured values. Whether the benchmark runs on the
subscription or on the API is open question 2; the arm format supports both. BEN-002 carries the
`[security]` tag for this.

### Decision 9: The result line

One JSON line per run, appended atomically, never rewritten:

- identity: `run_id`, `batch`, `arm`, `task`, `seed`, `size_class`, `source` (`bench` or
  `harbor:<dataset>`), `started_at`, `ended_at`, `wall_clock_seconds`;
- outcome: `status` (`completed`, `timeout`, `agent_error`, `infra_error`), `passed`, per-test
  results for fail-to-pass and pass-to-pass, `hidden_paths_overwritten`, `contamination_suspect`;
- size of the work: diff stats, `markdown_lines` (added lines in `*.md` files), `pr_count`
  (implementation branches integrated into the final state; 1 for A and B), the diff's path in the
  run directory;
- usage: per model, `input`, `output`, `cache_read`, `cache_write` token counts and the collector
  version (Decision 10);
- provenance: arm file hash, prompt hash, agent CLI version, `nogging_ref`, image digest, bench
  commit, `PREREGISTRATION.md` blob hash, `smoke` flag.

An `infra_error` line (the container did not start, the image did not build) is recorded too, so a
failed run is visible, and the report counts it apart from agent failures. `seed` is the replicate
index: the agents are not seedable, and the value only identifies repeated runs of the same arm on
the same ticket.

### Decision 10: Token usage through Nogging's collector

The roadmap names `nogg_usage.py`. In the current tree that module holds the quota snapshots
(rate-limit windows), not per-run token counts. The per-run usage ledger is the token-usage
collector behind `nogg token-usage` (`scripts/lib/token_usage_adapters.py` and its store), which
normalises Claude Code and Codex transcripts. This change uses that collector, which is what the
roadmap means by "the existing usage ledger".

`nogg token-usage` collects supervised sessions only and has no command that parses a given
transcript file. Adding one would change production code. So the run copies each container's
transcript directories out (all arms, so A, B and C are counted the same way, including every
planner, Lead and specialist session of C), and a bench-owned helper process normalises them with
Nogging's own Claude and Codex adapters from the host checkout, printing per-model counters as JSON
to the bench process. The bench package itself imports nothing from Nogging; the helper is the one
place that knows the adapters' location and entry points, it records the Nogging commit it read
them from, and a contract test feeds it a recorded Claude and a recorded Codex transcript fixture.
When the Phase 6 split moves the adapters, that test fails and only the helper changes. A small
`nogg token-usage` command that parses a given transcript would remove the helper; it is a
candidate for after the freeze.

### Decision 11: Preregistration before measurement

A measured run (any run that is not `--smoke`) refuses when `bench/PREREGISTRATION.md` is missing,
has uncommitted changes, or has no valid thresholds block, and when the task is not `accepted`. The
result line records the file's blob hash. `report` refuses to mix result lines with different
preregistration hashes unless told to, and lists any measured line written before the
preregistration's first commit. `--smoke` runs work on example and candidate tasks without a
preregistration, carry `smoke: true`, and are left out of every report table.

`PREREGISTRATION.md` is written by the Product Owner in BEN-006. Besides prose it carries one fenced
`yaml` thresholds block that `validate` checks and `report` evaluates. The block names: the primary
comparisons (for example D against A, and for Phase 0 C against A and B), the definition of an
accepted ticket for the cost metric (hidden tests pass, or hidden tests pass and the blinded review
says merge), the thresholds (the roadmap proposes: D at least as good as A on hidden tests, cost
per accepted ticket at most equal, and on medium and large tickets D at least 15 percentage points
ahead of A), the minimum effect treated as a difference (smaller is a tie), the significance level,
and the reproducibility criterion that decides whether two runs of one arm on one ticket are
comparable.

### Decision 12: Harbor adapter

Harbor runs a task in its own container and loads a custom agent by import path. The adapter is a
class in `nogg_bench.harbor` that takes an arm file, installs that arm's agent (and for a `nogging`
arm, Nogging at `nogging_ref` and its dependencies) into Harbor's environment, runs it with the
task instruction as the brief and the arm's timebox, copies the transcripts out through the same
usage helper, and writes the same result line with `source: harbor:<dataset>`. Harbor's own
verifier decides pass or fail for its datasets; the adapter maps that verdict onto `passed` and the
per-test fields that exist. Harbor is pinned in the `harbor` extra. The implementer first checks
the installed Harbor's agent interface (base class, install and run hooks, environment exec, log
directory) against its documentation and records the version; a mismatch with this design is a
discovery, not a guess. Tests use a fake environment object; a real Harbor run on a FeatureBench
task happens in BEN-007.

### Decision 13: Review pack and report

**Review pack.** `nogg-bench review-pack --batch <batch> --out <dir>` takes the completed runs of a
batch, gives each a random item label, shuffles the order, and writes per item the task's issue text
and the diff with process artefacts removed: `openspec/`, `.beads/`, `.nogging/`, `.claude/`,
`.codex/`, `.pi/`, `.agents/`, `AGENTS.md`, `CLAUDE.md`, and Bead tokens, `Nogging-Writer:` and
`Co-authored-by:` lines in commit text. Markdown lines and the pull request count are already in
the result line, so the reviewer does not need them. The pack holds a record sheet (one row per
item: merge decision `merge`, `merge-after-changes` or `reject`; defect count by severity; review
minutes; free comment). The key from item label to run ID is written outside the pack directory.
`nogg-bench review-pack --import <sheet> --key <key>` validates the filled sheet and appends review
records. A pack refuses to include a run whose diff still contains a stripped marker after
anonymisation, and names it.

**Report.** `nogg-bench report --batch <batch>... --out bench/reports/<name>/` reads result lines,
review records, `bench/prices.yaml` and the thresholds block, and writes `report.md`, `runs.csv`
(every run, failed and smoke runs flagged) and `metadata.json` (bench commit, arm files, prompts,
the `AGENTS.md` of each Nogging ref, model IDs, effort levels, agent versions, image digests). It
pairs runs per ticket: McNemar's exact test on the discordant pairs for pass/fail, the exact sign
test for cost per run with ties dropped; with several seeds, a ticket's arm value is the majority
pass and the median cost, and the report also shows the spread between seeds. Tables are per size
class and overall. Cost uses list prices from `bench/prices.yaml` (USD per million input, output,
cache-read and cache-write tokens, with source URL and date per model); a model without a price is
reported as unknown cost, never as zero. The report evaluates each preregistered threshold as met,
not met or tie, and states the deviation from real use (no human approval in Nogging arms).

### Decision 14: Product Owner tasks are fenced off from Leads

BEN-006 and BEN-007 carry `[po-only]` in their title. After materialisation the planner adds the
label `po-only`, sets the assignee to `product-owner`, and appends a note that no Lead or
specialist claims them. A Lead never claims a `po-only` Bead and the Orchestration Agent never
launches a Lead for one; `bd ready --exclude-label po-only` lists the Leads' work. An agent may
help on request (propose candidate tickets as `status: candidate`, draft a preregistration for the
Product Owner to edit), but the selection, the hidden-test check, the thresholds and the start of
measured runs are the Product Owner's. The Orchestration Agent may run batches only on an explicit
`/orchestrate takeover code` instruction for BEN-007.

### Decision 15: The feature freeze lives in `AGENTS.md`

The roadmap freezes, from now on, new features in dispatch, loops and session wake, and the
Antigravity support, until the baseline report exists; bug fixes continue. Planners and Leads both
read `AGENTS.md` first, so the rule is a short section there, directly after the hard rules. The
shipped `templates/agents-block.md` does not change: the freeze is about developing Nogging, not
about consumer repositories. The rule ends when the baseline report of BEN-007 is committed and the
Product Owner lifts it; removing the section is a planning edit.

### Decision 16: Dependencies and parallel waves

```text
BEN-001 ──┬── BEN-002 ── BEN-003 ──┐
          ├── BEN-004 ─────────────┤
          ├── BEN-005 ─────────────┼── BEN-007 (po-only)
          └── BEN-006 (po-only) ───┘
```

- Wave 1: BEN-001.
- Wave 2, in parallel: BEN-002, BEN-004, BEN-005 (all against BEN-001's contracts and fixtures) and
  BEN-006 (the Product Owner curates in the BEN-001 format with `nogg-bench validate`).
- Wave 3: BEN-003 needs BEN-002's container run and usage helper.
- Wave 4: BEN-007 needs everything.

BEN-003 depends on BEN-002 because the adapter reuses the agent launch and usage capture; copying
them would give two collectors and two meanings of a result. BEN-006 depends only on BEN-001: the
metric definitions it preregisters are in the spec, so it need not wait for the report code.

### Decision 17: Tests and execution discipline

Small and medium tests run offline with no Docker daemon, no Harbor, no agent CLI and no network:
the `docker` CLI is a stub on `PATH` that records its argv, agents are stub executables that write a
transcript fixture and a diff, Harbor's environment is a fake object, and the clock is injected. One
large test per runner (BEN-002, BEN-003) runs a real container on an example task only when an
explicit environment variable is set; CI does not set it. The real runs are BEN-007.

## Risks / Trade-offs

- **Thirty tickets show only large effects** (about 15 percentage points and more). → Thresholds
  are preregistered, and smaller differences count as a tie.
- **Arm C is hard to drive unattended** (tmux sessions, Beads and Dolt in a container, no human to
  answer a prompt). → The driver is bench code with a timebox; a stalled session ends as `timeout`
  with its transcript kept. The pilot exists to find these failures before the full run.
- **Contamination through the network or training data.** → History truncated, web tools off,
  transcript scan, issues closed after the models' cutoff preferred (BEN-006).
- **The usage helper reaches into Nogging's adapters.** → One helper, one contract test, the
  Nogging commit recorded (Decision 10).
- **Credentials inside autonomous containers.** → By reference only, `0600`, removed after the
  run, redacted logs; subscription or API is the Product Owner's call.
- **The Docker host.** The delivery host is a Raspberry Pi (arm64); some repositories' and
  FeatureBench's images may be x86-only, and a full run is long. → Open question 4.
- **Cost.** Pilot 36 runs, full run 270 runs for A, B and C at 3 seeds. → Pilot first; the full run
  starts only after the pilot meets the reproducibility criterion.

## Migration Plan

Nothing to migrate. `bench/` is new and unpublished. Removing the change means deleting `bench/`,
the bench workflow and the freeze section.

## Open Questions

These are the Product Owner's decisions. This change does not decide them, and BEN-006 and BEN-007
cannot finish without them:

1. **Which three repositories?** Two Python, one TypeScript; actively maintained, permissive
   licence, test run under 10 minutes, not among the most-used training sources.
2. **Subscription or API for the benchmark runs?** It decides the credential mode in the arm files
   (Decision 8), the cost accounting (list prices are applied either way), and quota planning.
3. **Who does the blinded review?** The reviewer must not have seen the runs; the review minutes
   are a metric.
4. **Which Docker host?** The Raspberry Pi delivery host or another machine (architecture, disk,
   run time, and whether an egress allow-list can be set up there).
