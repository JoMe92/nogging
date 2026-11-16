## Why

Nogging v3.6.0 applies its full ceremony to every change: one Bead, one session, one worktree,
one pull request, a full OpenSpec change and a 30-second mirror. Nobody has measured whether that
ceremony pays for itself. The Product Owner's roadmap (Rev 16, 2026-11-16) therefore puts a
benchmark first: every later change to Nogging has to show its effect on this benchmark and sit
behind a configuration switch.

Public benchmarks give an agent one issue and check hidden tests. They measure the model and the
agent loop, not what Nogging claims to add: planning, decomposition, review effort and cost per
accepted change. So the main benchmark is our own paired ticket benchmark on foreign repositories,
with a FeatureBench subset as an external anchor and Harbor as the container runner.

This is Phase 0 of the roadmap and the only phase that still runs as a full OpenSpec change before
a fast lane exists. At its end there are numbers for arms A, B and C, and no Nogging production
code has changed.

## What Changes

- **A separate benchmark package, `bench/`.** A Python package with its own pytest suite and its
  own command line, `bench/nogg-bench`. It talks to Nogging only through Nogging's command line and
  the files Nogging writes, never through imports of Nogging internals, so the later split of
  `scripts/nogg` leaves it untouched. It is not part of the published npm package and the
  installer never copies it.
- **A task format and a validator.** Each ticket is `bench/tasks/<id>/task.yaml`: repository,
  base commit, issue text, hidden tests from the original pull request (fail-to-pass and
  pass-to-pass), size class and a curation status. `nogg-bench validate` checks tasks, arm files,
  result lines, review records and the preregistered thresholds. Three example tasks ship with it.
- **Arms and runs.** Arms are files under `bench/arms/`. `nogg-bench run --arm --task --seed`
  starts a container, runs the arm's agent inside a timebox, saves the diff and the token usage,
  then applies the hidden tests, which were outside the container until the agent ended, and
  appends one line to `bench/results/*.jsonl`, failures and timeouts included.
- **A Harbor adapter.** The same arms run as a Harbor agent loaded by import path, so FeatureBench
  tasks, and later SWE-bench Pro tasks, run with the same arms and the same result line.
- **A blinded review pack.** `nogg-bench review-pack` writes anonymised diffs in random order and a
  record sheet for the merge decision, the defects and the review minutes; the key that maps items
  back to arms stays out of the pack.
- **A paired report.** `nogg-bench report` pairs runs per ticket (McNemar for pass/fail, sign test
  for cost), tabulates per size class, checks the preregistered thresholds and exports every run as
  CSV, failed runs included.
- **Curation and runs stay with the Product Owner.** Choosing the 30 tickets, checking their hidden
  tests, writing `bench/PREREGISTRATION.md`, and running the pilot and the full run are the
  Product Owner's tasks. An agent may propose candidate tickets; it does not select them. No Lead
  claims those two tasks.
- **A feature freeze, recorded in `AGENTS.md`.** Until the baseline report exists, dispatch, loops,
  session wake and Antigravity get no new features, only bug fixes. Planners and Leads read the rule
  in `AGENTS.md`.

## Done when (the roadmap's acceptance for Phase 0)

- The pilot (12 tickets, arms A, B and C, one run each) completes with no manual intervention.
- Two runs of the same arm on the same ticket give comparable measurements, by the criterion the
  Product Owner fixes in `bench/PREREGISTRATION.md` before the first run.
- The baseline report for A, B and C, with its raw run data, is committed to the repository.
- No Nogging production code changed in this change.

## Capabilities

### New Capabilities

- `impact-benchmark`: the paired ticket benchmark: task format and validation, arms and runs,
  hidden-test isolation, usage capture, the Harbor adapter, the blinded review pack, the paired
  report, the preregistration gate and the Product Owner's curation.

### Modified Capabilities

None. Nogging's own behaviour does not change.

## Impact

- New: `bench/` (package, tests, tasks, arms, results, reports, `PREREGISTRATION.md`), and one CI
  workflow that runs the bench suite when `bench/` changes.
- `AGENTS.md`: a short repository rule for the feature freeze. The shipped agents block
  (`templates/agents-block.md`) does not change, so consumer repositories are not affected.
- Unchanged: `scripts/`, `bin/`, `templates/`, `.claude/`, `.codex/`, `.pi/`, `.nogging/` and
  `package.json`. The roadmap's `nogg bench` name is served by `bench/nogg-bench`; a `nogg bench`
  alias inside `scripts/nogg` would be a production change and waits until after the baseline.
- Cost: the pilot is 36 runs; the full run with arms A, B and C on 30 tickets and 3 seeds is 270
  runs. The roadmap's estimate is 2.35 to 4.23 US dollars per ticket run at Sonnet level, more on
  Opus. Whether runs use a subscription or the API is an open Product Owner question.
