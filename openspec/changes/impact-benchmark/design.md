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
  of the hidden tests stay manual, or the benchmark is open to attack. **Revised 2026-11-17
  (Decisions 18 and 19):** the selection is now mechanical, by fixed preregistered criteria, an
  automatic hidden-test check and a seeded draw, so nobody's judgement picks a ticket. The report
  names this deviation from the roadmap's hand-curation rule.
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
- Choosing repositories or tickets by judgement. Since the 2026-11-17 revision they are drawn
  mechanically (Decisions 18 and 19); the thresholds are the roadmap's (Decision 22).
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

`accepted` means the hidden tests have been run against `base_commit` (the fail-to-pass tests
fail, the pass-to-pass tests pass) and against the original fix (all pass), with who or what ran
them and when recorded. `validate` refuses an `accepted` task without those two fields and refuses
any `fail_to_pass` identifier that is also in `pass_to_pass`. **Revised 2026-11-17:** the check is
`nogg-bench verify` (Decision 18), which records itself and the bench commit in
`hidden_tests_verified_by`, and only `nogg-bench select` (Decision 19) flips a verified candidate
to `accepted`; nobody sets the status by hand. A measured run refuses a task that is not `accepted`
(Decision 11), so an unverified or undrawn candidate never enters the data.

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
runs separately. A tighter egress allow-list depends on the Docker host; the runs use the x86_64
PC (Decision 22), and an allow-list there is optional, not a precondition of the pilot. The
container options a `nogging` arm needs are Decision 20.

### Decision 8: Credentials

The arm file names how its agent authenticates by reference only: an environment variable name
for an API key, or a credential directory for a subscription login. The run passes the value into
the container through an environment file or a read-only mount created with mode `0600` and removed
after the run. No credential appears on a command line, in a result line, in a log, in a report or
in a fixture; the run's log writer redacts the configured values. The arm format supports both
modes; the pilot and the full run use the subscription (Decision 22). BEN-002 carries the
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

`PREREGISTRATION.md` is written in BEN-006, since the 2026-11-17 revision by an agent with the
roadmap's thresholds (Decision 22), and it also fixes the selection rule and its seed (Decision
19). Besides prose it carries one fenced `yaml` thresholds block that `validate` checks and
`report` evaluates. The block names: the primary
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

### Decision 14: Product Owner tasks are fenced off from Leads (revised 2026-11-17)

Originally BEN-006 and BEN-007 were `po-only`. Since the 2026-11-17 revision only two tasks are:
BEN-012, the blinded review of the pilot, which is the Product Owner's one piece of hand work in
the benchmark, and BEN-009, adding the bench CI workflow, which needs a GitHub credential with the
`workflow` scope that no agent session holds. Both carry `[po-only]` in their title; after
materialisation the planner adds the label `po-only`, sets the assignee to `product-owner`, and
appends a note that no Lead or specialist claims them. A Lead never claims a `po-only` Bead and the
Orchestration Agent never launches a Lead for one; `bd ready --exclude-label po-only` lists the
Leads' work. BEN-006 and BEN-007 lose the label and the `product-owner` assignee and become
ordinary agent tasks, like the new BEN-008, BEN-010, BEN-011, BEN-013 and BEN-014. No agent fills
in a review sheet, and no agent edits the preregistration after its first measured run.

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

**Revised 2026-11-17.** Waves 1 to 3 are done (BEN-001 to BEN-005 are closed). The rest:

```text
BEN-006 prereg ───────────┐
BEN-008 curation tools ───┴── BEN-011 curation run ──┐
BEN-010 arm C unattended ────────────────────────────┴── BEN-007 pilot ──┬── BEN-012 review (po-only) ──┐
                                                                          └── BEN-013 full run ──────────┴── BEN-014 baseline report
BEN-009 bench workflow (po-only, independent)
```

- Wave 4, in parallel now: BEN-006, BEN-008, BEN-010, and BEN-009 for the Product Owner.
- Wave 5: BEN-011 needs the committed seed of BEN-006 and the tools of BEN-008.
- Wave 6: BEN-007 needs the drawn tasks of BEN-011 and the unattended arm C of BEN-010.
- Wave 7, in parallel: the Product Owner reviews the pilot (BEN-012) while BEN-013 runs the full
  run, which starts only when the pilot has met the reproducibility criterion.
- Wave 8: BEN-014 needs the review records of BEN-012 and the results of BEN-013.

BEN-007 no longer depends on BEN-003: the Harbor proof run moved to BEN-013, which takes that edge.

### Decision 17: Tests and execution discipline

Small and medium tests run offline with no Docker daemon, no Harbor, no agent CLI and no network:
the `docker` CLI is a stub on `PATH` that records its argv, agents are stub executables that write a
transcript fixture and a diff, Harbor's environment is a fake object, and the clock is injected. One
large test per runner (BEN-002, BEN-003) runs a real container on an example task only when an
explicit environment variable is set; CI does not set it. The real runs are BEN-007 and BEN-013.

### Decision 18: Candidates are collected and verified mechanically (BEN-008, BEN-011)

The roadmap kept selection and the hidden-test check as hand work so that nobody could steer the
benchmark. The Product Owner delegated every open question on 2026-11-17, and the Orchestration
Agent chose to replace the hand work by a procedure that steers nothing either: fixed criteria, an
automatic check and a seeded draw (Decision 19). Every criterion below is written into
`PREREGISTRATION.md` in BEN-006, with the numbers proposed here unless BEN-006 records a reason to
differ, and is committed before any candidate is collected.

**Repositories.** `nogg-bench candidates repos` searches GitHub through the `gh` command line
(read-only API calls; the bench package still imports nothing from Nogging) and writes a pool
snapshot with its query and time. A repository qualifies when it:

- has Python or TypeScript as its primary language;
- carries a permissive licence by SPDX identifier (MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause,
  ISC);
- is actively maintained: a commit on the default branch in the last 90 days and at least 10
  merged pull requests in the last 180 days;
- is not among the most-used training sources: not on the committed exclusion list (the
  repositories of SWE-bench, SWE-bench Verified, the public SWE-bench Pro set, SWE-Gym and
  FeatureBench, each list with its source URL) and between 300 and 20,000 stars;
- has a test suite that installs and runs green at its default branch head in the task container
  in under 10 minutes on the run host, measured by `nogg-bench verify`.

Two Python repositories and one TypeScript repository are taken in draw order (Decision 19). A
repository whose environment recipe the curating agent cannot make run within the time limit is
skipped with its reason recorded in the pool log; skipping is the only freedom the agent has, and
every skip is visible.

**Issues.** `nogg-bench candidates issues` lists, for each chosen repository, issues that:

- were closed as completed and are linked to exactly one merged pull request whose author is not a
  bot account;
- whose pull request changes both test and non-test files; the test-file changes become the hidden
  test patch, the pull request's base becomes `base_commit`;
- whose issue text does not contain the fix pull request's URL or a diff;
- carry a size class by the pull request's non-test changes: `small` 1 to 2 files, `medium` 3 to 5
  files and under 300 changed lines, `large` 6 or more files or 300 or more lines.

Each issue is written as a `curation.status: candidate` task in the BEN-001 format, with
`issue_closed_at` recorded so the draw can prefer issues closed after the models' training cutoff.

**Verification.** `nogg-bench verify` runs each candidate in its task container on the run host: the
suite with the hidden patch on `base_commit` and on the original fix. Fail-to-pass is the set that
fails at the base and passes on the fix; pass-to-pass is the set that passes on both. A candidate
is verified when fail-to-pass is not empty, and both sides are run twice with identical outcomes; a
flaky test, a setup failure or a suite over the timeout drops the candidate with the reason
recorded. `verify` writes the identifiers, records `hidden_tests_verified_by: nogg-bench verify
<bench commit>` and `verified_on`, and never sets `accepted`.

BEN-008 builds and tests the three commands offline against stubs (`gh`, `docker`, a fixture
repository). BEN-011 runs them on the run host and commits the pool, the candidates, the
verification records and the draw.

### Decision 19: The selection is a seeded draw from the verified candidates

`PREREGISTRATION.md` carries a `selection` block next to the thresholds block: `method:
seeded-draw`, the integer `seed`, the counts (10 per size class, 4 of them per class for the pilot),
the training-cutoff date per arm model with its source, and the criteria of Decision 18. BEN-006
commits it before BEN-011 collects anything.

The draw is a pure function of the seed and the committed pool, reproducible by anyone without
Python's random module: every item's rank key is the SHA-256 of `"<seed>:<key>"` in hex, sorted
ascending, where the key is a repository's full name or a candidate's task ID. Repositories are
drawn per language in rank order. Tickets are drawn per size class from the verified candidates,
those closed after the latest training cutoff of the arm models first and the others after them,
each group in rank order; the first 10 become `accepted`, and the first 4 of those 10 get
`curation.pilot: true`. `nogg-bench select` writes the statuses and `bench/curation/selection.json`
(seed, preregistration blob hash, pool hash, the ranked lists). It refuses when a size class has
fewer than 10 verified candidates (naming the class), and when the commit that introduced the
preregistration's selection block is not an ancestor of the commit that first added the candidate
pool, so a seed cannot be chosen after its outcome is known. Running `select` again on the same
pool gives the same result. A shortfall is a blocking discovery for a planning session.

`report` states in `report.md`, whenever the selection block says `seeded-draw`, that the tickets
were selected mechanically, deviating from the roadmap's hand-curation rule, and why.

### Decision 20: Arm C finishes unattended in a container

The code review of BEN-002 (discovery on SPEC-ihi0) found that an unattended Nogging v3.6.0 cannot
finish inside the run container: its autonomous Lead ends by opening a pull request, and the
container has a local bare origin and no forge; and its execution launches go through
`scripts/openspec-sandbox`, which calls `unshare --user --mount`, which Docker's default seccomp
and AppArmor profiles refuse. Arm C must stay v3.6.0 unchanged, so the bench supplies the
environment instead (BEN-010):

- **A local forge shim.** The driver puts a `gh` executable on the container's `PATH` that answers
  the calls a v3.6.0 Lead makes (`pr create`, `pr view`, `pr checks`, `pr merge`) against the local
  bare origin: it records each pull request in the run directory, reports checks as passed, and
  never reaches the network. The pull requests it records are `pr_count`'s evidence; the diff
  against `base_commit` stays the measured work.
- **The same container options for every arm.** Every run's container gets the options that
  `unshare --user --mount` needs and nothing more (no `--privileged`, no added capability beyond
  what the smoke run proves necessary), so arms differ only in their agent; the options are
  recorded in the result's provenance and in `metadata.json`.
- **The open checks of the discovery.** `bd` and `dolt` without the host's Dolt server, a Claude
  session launched in tmux without onboarding or trust prompts, and Codex with web search disabled
  are each proven by one real smoke run of arm C (and the Codex flag by one of arm B) on an
  example task; the smoke runs may use the Raspberry Pi (Decision 22).

### Decision 21: What the Product Owner reviews

The Product Owner reviews the pilot: one blinded pack of the 36 pilot runs (12 tickets, arms A, B
and C, seed 1), through `review-pack` and `--import`. The second-seed reproducibility runs and the
full run are not reviewed. So the review metrics (merge decision, defects, review minutes) are
reported for the pilot tickets, and the primary metrics come from the full run, where an accepted
ticket for the cost metric is one whose hidden tests pass. `PREREGISTRATION.md` states this scope
and that definition. BEN-014 writes two reports, `bench/reports/pilot/` (pilot batch with the
review records) and `bench/reports/baseline/` (full run), and the baseline report names the pilot
report for the review metrics.

### Decision 22: The Product Owner's open questions, decided 2026-11-17

On 2026-11-17 the Product Owner delegated every open question to the Orchestration Agent
("Entscheide du alles"). Its decisions, recorded here by the planning session (delegated by the
Product Owner):

1. **Curation is mechanical** (former question 1, which three repositories): fixed criteria, an
   automatic hidden-test check and a seeded draw of the 30 tickets (10 per size class) and the 12
   pilot tickets (Decisions 18 and 19). BEN-008 builds the tools, BEN-011 runs them. The report
   names the deviation from the roadmap's hand-curation rule.
2. **BEN-006 is an agent task.** It writes `PREREGISTRATION.md` with the roadmap's thresholds:
   arm D at least as good as arm A on hidden tests, D's cost per accepted ticket at most A's, and on
   medium and large tickets D at least 15 percentage points ahead of A; McNemar's exact test for
   pass or fail and the exact sign test for cost; a difference under 15 percentage points is a tie.
   For Phase 0 it adds C against A and C against B as the primary comparisons, on the same tests,
   and it preregisters the Phase 1 gate of `adaptive-ceremony` now, because nothing may be added
   after the first measured run: on the 10 small tickets, arm D with `ceremony.mode: adaptive`
   uses fewer tokens per run than arm C by the exact sign test, and does not pass less often.
   It also fixes the seed and the selection rule (Decision 19), the review scope (Decision 21), a
   significance level of 0.05, and a reproducibility criterion: on the 12 pilot tickets a second
   seed of arms A and C agrees with the first on pass or fail for at least 10 tickets, and the median
   relative cost difference between the two seeds is at most 25 percent. The file is committed
   before the draw and before any measured run, and is not edited after the first measured run.
3. **Subscription, not API** (former question 2), for the pilot and the full run. Cost is the
   token count from the usage ledger converted at list prices (`bench/prices.yaml`), as Decision
   13 already does. The API is used only when the subscription's limits block the full run: the
   Lead of BEN-013 then records a blocking discovery, the Orchestration Agent decides, and a switch
   happens between batches, never inside one, changing only the arms' credential reference.
4. **The Product Owner reviews blind** (former question 3), through `nogg-bench review-pack`, the
   pilot's 36 diffs (Decision 21). This is the Product Owner's only hand work in the benchmark.
5. **The run host is the x86_64 PC with Docker** (former question 4) for the pilot and the full
   run. A smoke run of one or two tickets may run on the Raspberry Pi beforehand; smoke runs are
   `--smoke` and never data.
6. **BEN-007 is cut** so that the runs are agent tasks (BEN-007 pilot, BEN-013 full run) and only
   the blinded review stays `po-only` (BEN-012).
7. **The bench CI workflow becomes its own `po-only` task, BEN-009.** BEN-001 shipped without
   `.github/workflows/bench.yml` because the agents' GitHub token lacks the `workflow` scope; the
   file waits in the main checkout's `.nogging/state/bench.yml.pending`. The Product Owner pushes it
   or grants the scope.

Not among the delegated decisions: the arms' model, effort and timebox. This plan keeps them as
BEN-002 committed them (Decision 6); BEN-007 changes only the credential reference to the
subscription logins. A change to them before the pilot needs the Orchestration Agent's decision.

## Risks / Trade-offs

- **Thirty tickets show only large effects** (about 15 percentage points and more). → Thresholds
  are preregistered, and smaller differences count as a tie.
- **Arm C is hard to drive unattended** (tmux sessions, Beads and Dolt in a container, no human to
  answer a prompt). → The driver is bench code with a timebox; a stalled session ends as `timeout`
  with its transcript kept. The pilot exists to find these failures before the full run.
- **Contamination through the network or training data.** → History truncated, web tools off,
  transcript scan, issues closed after the models' cutoff drawn first (Decision 19).
- **Mechanical curation still has a lever: the environment recipe.** The curating agent could skip
  a repository by failing to make its suite run. → A skip is allowed only for a stated reason,
  every skip is in the committed pool log, and repositories are tried strictly in draw order.
- **The draw may leave a repository with few or no tickets in a size class.** → Accepted; the
  report shows the repository mix per class. A class with fewer than 10 verified candidates stops
  the draw and goes back to planning.
- **The usage helper reaches into Nogging's adapters.** → One helper, one contract test, the
  Nogging commit recorded (Decision 10).
- **Credentials inside autonomous containers.** → By reference only, `0600`, removed after the
  run, redacted logs; the subscription logins are mounted, never copied into a result.
- **The Docker host.** The delivery host is a Raspberry Pi (arm64); some repositories' and
  FeatureBench's images may be x86-only, and a full run is long. → The x86_64 PC runs the pilot
  and the full run (Decision 22); the Pi only smoke runs.
- **Subscription limits stretch the full run over days.** → Batches resume (Decision 9); an API
  switch needs a blocking discovery and the Orchestration Agent's decision (Decision 22).
- **One reviewer, 36 diffs.** The review metrics rest on the pilot only. → Stated in the
  preregistration and the report; the primary metrics come from the full run.
- **Cost.** Pilot 36 runs, full run 270 runs for A, B and C at 3 seeds. → Pilot first; the full run
  starts only after the pilot meets the reproducibility criterion.

## Migration Plan

Nothing to migrate. `bench/` is new and unpublished. Removing the change means deleting `bench/`,
the bench workflow and the freeze section.

## Open Questions

None. The four questions this section listed until 2026-11-17 (which three repositories,
subscription or API, who reviews blind, which Docker host) were delegated by the Product Owner and
are decided in Decision 22.
